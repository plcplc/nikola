-- Copyright (c) 2009-2010
--         The President and Fellows of Harvard College.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions
-- are met:
-- 1. Redistributions of source code must retain the above copyright
--    notice, this list of conditions and the following disclaimer.
-- 2. Redistributions in binary form must reproduce the above copyright
--    notice, this list of conditions and the following disclaimer in the
--    documentation and/or other materials provided with the distribution.
-- 3. Neither the name of the University nor the names of its contributors
--    may be used to endorse or promote products derived from this software
--    without specific prior written permission.

-- THIS SOFTWARE IS PROVIDED BY THE UNIVERSITY AND CONTRIBUTORS ``AS IS'' AND
-- ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
-- IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
-- ARE DISCLAIMED.  IN NO EVENT SHALL THE UNIVERSITY OR CONTRIBUTORS BE LIABLE
-- FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
-- DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
-- OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
-- HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
-- LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
-- OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
-- SUCH DAMAGE.

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Nikola.ToC (
    C(..),

    ExecConfig(..),
    CFun(..),
    configToLaunchParams,

    compileFun,
    compileTopFun
  ) where

import Control.Applicative
import Control.Exception
import Control.Monad.Error
import Control.Monad.State
import Data.Data
import qualified Data.Map as Map
import Data.Maybe (fromJust)
import Data.List (find, foldl')
import qualified Data.Set as Set
import Language.C.Quote.CUDA
import qualified Language.C.Syntax as C
import qualified Language.C.Syntax
import Text.PrettyPrint.Mainland hiding (nest)

import Nikola.CGen
import Nikola.Check
import Nikola.Syntax
import Nikola.Exec

-- | Index into a thread block
data BlockVar = BlockVar { blockDim   :: Int
                         , blockWidth :: Int
                         }
  deriving (Eq, Ord, Show)

instance Pretty BlockVar where
    ppr = text . show

instance ToExp BlockVar where
    toExp = go . blockDim
      where
        go :: Int -> C.Exp
        go 0 = [$cexp|threadIdx.x|]
        go 1 = [$cexp|threadIdx.y|]
        go 2 = [$cexp|threadIdx.z|]
        go _ = error "bad thread block variable"

-- | Index into a grid
data GridVar = GridVar { gridDim      :: Int
                       , gridBlockVar :: BlockVar
                       }
  deriving (Eq, Ord, Show)

instance Pretty GridVar where
    ppr = text . show

instance ToExp GridVar where
    toExp (GridVar { gridBlockVar = t }) =
        [$cexp|(blockIdx.x + blockIdx.y*gridDim.x)*$(blockWidth t) + $t|]

-- | A compiled expression.
data CExp = ScalarCExp C.Exp
          | VectorCExp C.Exp C.Exp
          | MatrixCExp C.Exp N N N
          | FunCExp String Rho [DevAlloc] [DevAlloc]

instance Pretty CExp where
    ppr = ppr . toExp

instance ToExp CExp where
    toExp (ScalarCExp e)       = e
    toExp (VectorCExp e _)     = e
    toExp (MatrixCExp e _ _ _) = e
    toExp (FunCExp v _ _ _)    = [$cexp|$id:v|]

vectorSize :: CExp -> C.Exp
vectorSize (VectorCExp _ n) = n

vectorSize _ =
    error "Impossible: tried to take size of non-vector"

toArgs :: CExp -> C [C.Exp]
toArgs (ScalarCExp e) =
    return [e]

toArgs (VectorCExp e ne) =
    return [e, ne]

toArgs (MatrixCExp e s r c) = do
    ns <- evalN s
    nr <- evalN r
    nc <- evalN c
    return [e, ns, nr, nc]

toArgs (FunCExp {}) =
    error "The impossible happened: an embedded higher-order function!"

toTempArgs :: CExp -> C [C.Exp]
toTempArgs (ScalarCExp e) =
    return [e]

toTempArgs (VectorCExp e ne) =
    return [e, [$cexp|&$ne|] ]

toTempArgs (MatrixCExp e _ _ _) =
    return [e]

toTempArgs (FunCExp {}) =
    error "The impossible happened: an embedded higher-order function!"

-- | An execution configuration.
data ExecConfig = ExecConfig
    {  gridDimX  :: N
    ,  gridDimY  :: N
    ,  blockDimX :: Int
    ,  blockDimY :: Int
    ,  blockDimZ :: Int
    }
  deriving (Data, Typeable)

configToLaunchParams :: ExecConfig -> Ex (Int, Int, Int, Int, Int)
configToLaunchParams config = do
    gridW <- compGridW
    gridH <- compGridH
    return (dimX, dimY, dimZ, gridW, gridH)
  where
    dimX, dimY, dimZ :: Int
    dimX = blockDimX config
    dimY = blockDimY config
    dimZ = blockDimZ config

    compGridW, compGridH :: Ex Int
    compGridW = evalN (gridDimX config)
    compGridH = evalN (gridDimY config)

-- | A compiled function.
data CFun a = CFun
    {  cfunName       :: String
    ,  cfunDefs       :: [C.Definition]
    ,  cfunAllocs     :: [Rho]
    ,  cfunExecConfig :: ExecConfig
    }

instance Pretty (CFun a) where
    ppr f = text (cfunName f) </>
            stack (map ppr (cfunDefs f))

-- | An on-device allocation needed by a compiled expression. We may need to
-- allocate device memory to hold intermediate results or to hold the final
-- result of a computation.
data DevAlloc = DevAlloc
    {  devAllocVar    :: String
    ,  devAllocParams :: [C.Param]
    ,  devAllocType   :: Rho
    }

-- | Context in which compilation occurs.
data Ctx = TopFun    { level :: Int }
         | NestedFun { level :: Int }

nest :: Ctx -> Ctx
nest ctx = ctx { level = level ctx + 1 }

data CState = CState
    {  cuniq    :: Int

    ,  cvars    :: Map.Map Var Rho
    ,  cvarExps :: Map.Map Var CExp

    ,  cgenenv  :: CGenEnv

    ,  cdevAllocs  :: [DevAlloc]
    ,  cnExps      :: Map.Map N C.Exp

    ,  cgridVars      :: Map.Map N GridVar
    ,  cblockVars     :: [BlockVar]
    ,  cusedBlockVars :: Set.Set BlockVar
    }

newtype C a = C { unC :: StateT CState (ErrorT SomeException IO) a }
  deriving (Monad, MonadIO,
            MonadState CState,
            MonadError SomeException)

instance MonadUniqueVar C where
    newUniqueVar v = do
        u <- gets cuniq
        modify $ \s -> s { cuniq = u + 1 }
        return $ Var (v ++ show u)

instance MonadCheck C where
    lookupVar v = do
        maybe_tau <- gets $ \s -> Map.lookup v (cvars s)
        case maybe_tau of
          Just tau -> return tau
          Nothing -> faildoc $ text "Variable" <+> ppr v <+>
                     text "not in scope"

    extendVars vtaus act = do
        old_cvars <- gets cvars
        modify $ \s -> s { cvars = foldl' insert (cvars s) vtaus }
        x  <- act
        modify $ \s -> s { cvars = old_cvars }
        return x
      where
        insert m (k, v) = Map.insert k v m

instance MonadEvalN C.Exp C where
    evalN n = do
        maybe_ce <- lookupNExp n
        case maybe_ce of
          Nothing -> go n
          Just ce -> return ce
      where
        go :: N -> C C.Exp
        go n@(NVecLength {}) =
            faildoc $ text "Cannot evaluate:" <+> ppr n

        go n@(NMatStride {}) =
            faildoc $ text "Cannot evaluate:" <+> ppr n

        go n@(NMatRows {}) =
            faildoc $ text "Cannot evaluate:" <+> ppr n

        go n@(NMatCols {}) =
            faildoc $ text "Cannot evaluate:" <+> ppr n

        go (N i) =
            return [$cexp|$int:i|]

        go (NAdd n1 n2) = do
            e1 :: C.Exp <- evalN n1
            e2 :: C.Exp <- evalN n2
            return [$cexp|$e1 + $e2|]

        go (NSub n1 n2) = do
            e1 :: C.Exp <- evalN n1
            e2 :: C.Exp <- evalN n2
            return [$cexp|$e1 - $e2|]

        go (NMul n1 n2) = do
            e1 :: C.Exp <- evalN n1
            e2 :: C.Exp <- evalN n2
            return [$cexp|$e1 * $e2|]

        go (NNegate n) = do
            e :: C.Exp <- evalN n
            return [$cexp|-$e|]

        go (NDiv n1 n2) = do
            e1 :: C.Exp <- evalN n1
            e2 :: C.Exp <- evalN n2
            return [$cexp|$e1 / $e2|]

        go (NMod n1 n2) = do
            e1 :: C.Exp <- evalN n1
            e2 :: C.Exp <- evalN n2
            return [$cexp|$e1 % $e2|]

        go n@(NMin ns) = do
            vn <- gensym "tempn"
            addLocal [$cdecl|int $id:vn;|]
            es :: [C.Exp] <- mapM evalN ns
            cminimum vn es
            insertNExp n [$cexp|$id:vn|]
            return [$cexp|$id:vn|]
          where
            cminimum :: String -> [C.Exp] -> C ()
            cminimum _    []       = fail "cminimum"
            cminimum temp [e]      = addStm [$cstm|$id:temp = $e;|]
            cminimum temp [e1, e2] = addStm [$cstm|$id:temp = $e1 < $e2 ? $e1 : $e2;|]

            cminimum temp (e : es) = do
                cminimum temp es
                addStm [$cstm|if ($e < $id:temp) { $id:temp = $e; }|]

        go n@(NMax ns) = do
            vn <- gensym "tempn"
            addLocal [$cdecl|int $id:vn;|]
            es :: [C.Exp] <- mapM evalN ns
            cmaximum vn es
            insertNExp n [$cexp|$id:vn|]
            return [$cexp|$id:vn|]
          where
            cmaximum :: String -> [C.Exp] -> C ()
            cmaximum _    []       = fail "cmaximum"
            cmaximum temp [e]      = addStm [$cstm|$id:temp = $e;|]
            cmaximum temp [e1, e2] = addStm [$cstm|$id:temp = $e1 > $e2 ? $e1 : $e2;|]

            cmaximum temp (e : es) = do
                cmaximum temp es
                addStm [$cstm|if ($e > $id:temp) { $id:temp = $e; }|]

instance MonadCGen C where
    getCGenEnv = gets cgenenv

    putCGenEnv env = modify $ \s ->
        s { cgenenv = env }

instance Functor C where
    fmap = liftM

instance Applicative C where
    pure = return
    (<*>) = ap

runC :: C a -> IO a
runC m = do
    result <- runErrorT (evalStateT (unC m) emptyCState)
    case result of
      Left (SomeException e) -> throw e
      Right x ->                return x
  where
    emptyCState :: CState
    emptyCState = CState
        {  cuniq    = 0

        ,  cvars    = Map.empty
        ,  cvarExps = Map.empty

        ,  cgenenv = emptyCGenEnv

        ,  cdevAllocs  = []
        ,  cnExps      = Map.empty

        ,  cgridVars      = Map.empty
        ,  cblockVars     = [BlockVar 0 (fromInteger threadBlockWidth)]
        ,  cusedBlockVars = Set.empty
        }

runCFun :: C (String, [DevAlloc]) -> IO (CFun a)
runCFun comp = runC $ do
    (fname, allocs) <- comp
    cdefs           <- getsCGenEnv codeToUnit
    config          <- getExecConfig
    return CFun { cfunName       = fname
                , cfunDefs       = cdefs
                , cfunAllocs     = map devAllocType allocs
                , cfunExecConfig = config
                }

getExecConfig :: C ExecConfig
getExecConfig = do
    gridVars         <- gets (Map.toList . cgridVars)
    blockVars        <- gets cblockVars
    usedBlockVars    <- gets cusedBlockVars
    let (dimX, dimY) =  gridDims gridVars
    return ExecConfig { gridDimX  = dimX
                      , gridDimY  = dimY
                      , blockDimX = blockDim blockVars usedBlockVars 0
                      , blockDimY = blockDim blockVars usedBlockVars 1
                      , blockDimZ = blockDim blockVars usedBlockVars 2
                      }
  where
    blockDim :: [BlockVar] -> Set.Set BlockVar -> Int -> Int
    blockDim blockVars usedBlockVars i
        | length blockVars > i  && t `Set.member` usedBlockVars = blockWidth t
        | otherwise                                             = 1
      where
        t = blockVars !! i

    gridDims :: [(N, GridVar)] -> (N, N)
    gridDims ((n, g) : _) =
        (nGridDimX n w, nGridDimY n w)
      where
        w = (blockWidth . gridBlockVar) g

    gridDims _ = (1, 1)

withBlockVar :: Ctx -> (Maybe BlockVar -> C a) -> C a
withBlockVar (TopFun _) cont = do
    blockVars <- gets cblockVars
    case blockVars of
      v : vs -> do  modify $ \s ->
                      s { cblockVars     = vs
                        , cusedBlockVars = Set.insert v (cusedBlockVars s)
                        }
                    x <- cont (Just v)
                    modify $ \s -> s { cblockVars = v : vs }
                    return x
      [] -> cont Nothing

withBlockVar _ cont = cont Nothing

withGridVar :: Ctx -> N -> (Maybe GridVar -> C a) -> C a
withGridVar (TopFun 0) n cont = do
    maybe_g <- gets (Map.lookup n . cgridVars)
    case maybe_g of
      Just g -> cont (Just g)
      Nothing -> newGridVar >>= cont
  where
    newGridVar :: C (Maybe GridVar)
    newGridVar = do
        ngridVars <- gets (Map.size . cgridVars)
        case ngridVars of
          0 -> withBlockVar (TopFun 0) $ \maybe_t ->
               case maybe_t of
                 Nothing -> return Nothing
                 Just t -> do  let g = GridVar { gridDim = 0
                                               , gridBlockVar = t
                                               }
                               modify $ \s ->
                                   s { cgridVars = Map.insert n g
                                                   (cgridVars s) }
                               return (Just g)
          _ -> return Nothing

withGridVar _ _ cont = cont Nothing

insertNExp :: N -> C.Exp -> C ()
insertNExp n e = modify $ \s ->
    s { cnExps = Map.insert n e (cnExps s) }

lookupNExp :: N -> C (Maybe C.Exp)
lookupNExp n =
    gets $ \s -> Map.lookup n (cnExps s)

lookupVarExp :: Var -> C CExp
lookupVarExp v = do
    maybe_cexp <- gets $ \s -> Map.lookup v (cvarExps s)
    case maybe_cexp of
      Just cexp -> return cexp
      Nothing ->   faildoc $ text "Variable" <+> ppr v <+> text "not in scope"

extendVarExps :: [(Var, CExp)] -> C a -> C a
extendVarExps vexps act = do
    old_cvarExps <- gets cvarExps
    modify $ \s -> s { cvarExps = foldl' insert (cvarExps s) vexps }
    x  <- act
    modify $ \s -> s { cvarExps = old_cvarExps }
    return x
  where
    insert m (k, v) = Map.insert k v m

inNewCompiledFunction :: C a -> C a
inNewCompiledFunction comp = do
    old_cdevAllocs <- gets cdevAllocs
    old_cnExps  <- gets cnExps
    modify $ \s -> s { cdevAllocs  = []
                     , cnExps      = Map.empty
                     }
    x <- comp
    modify $ \s -> s { cdevAllocs  = old_cdevAllocs
                     , cnExps      = old_cnExps
                     }
    return x

addDevAlloc :: DevAlloc -> C ()
addDevAlloc alloc = modify $ \s ->
    s { cdevAllocs = alloc : cdevAllocs s }

getDevAllocs :: C [DevAlloc]
getDevAllocs = gets cdevAllocs

-- | Translate a base type to its C equivalent
baseTypeToC :: Tau -> C.Type
baseTypeToC UnitT  = [$cty|void|]
baseTypeToC BoolT  = [$cty|unsigned char|]
baseTypeToC IntT   = [$cty|long long|]
baseTypeToC FloatT = [$cty|float|]

-- | Translate a type to its C equivalent
typeToC :: Rho -> C.Type
typeToC (ScalarT tau)       = baseTypeToC tau
typeToC (VectorT tau _)     = [$cty|$ty:(baseTypeToC tau) *|]
typeToC (MatrixT tau _ _ _) = [$cty|$ty:(baseTypeToC tau) *|]
typeToC (FunT rhos rho)     = [$cty|$ty:(typeToC rho) (*)($params:params)|]
  where
    params :: [C.Param]
    params = map (\rho -> [$cparam|$ty:(typeToC rho)|]) rhos

-- | Allocate space for a function argument
allocArgs :: [(Var, Rho)] -> C [CExp]
allocArgs vtaus =
    mapM allocArg (vtaus `zip` [0..])
  where
    allocArg :: ((Var, Rho), Int) -> C CExp
    allocArg ((Var v, ScalarT tau), _) = do
        addParam [$cparam|$ty:cty $id:v|]
        return $ ScalarCExp [$cexp|$id:v|]
      where
        cty :: C.Type
        cty = baseTypeToC tau

    allocArg ((Var v, VectorT tau _), i) = do
        addParam [$cparam|$ty:cty* $id:v|]
        addParam [$cparam|int $id:vn|]
        let n = NVecLength i
        insertNExp n [$cexp|$id:vn|]
        return $ VectorCExp [$cexp|$id:v|] [$cexp|$id:vn|]
      where
        cty :: C.Type
        cty = baseTypeToC tau

        vn :: String
        vn = v ++ "n"

    allocArg ((Var v, MatrixT tau _ _ _), i) = do
        addParam [$cparam|$ty:cty* $id:v|]
        addParam [$cparam|int $id:vs|]
        addParam [$cparam|int $id:vr|]
        addParam [$cparam|int $id:vc|]
        let s = NMatStride i
        let r = NMatRows i
        let c = NMatCols i
        insertNExp s [$cexp|$id:vs|]
        insertNExp r [$cexp|$id:vr|]
        insertNExp c [$cexp|$id:vc|]
        return $ MatrixCExp [$cexp|$id:v|] s r c
      where
        cty :: C.Type
        cty = baseTypeToC tau

        vs, vr, vc :: String
        vs = v ++ "s"
        vr = v ++ "r"
        vc = v ++ "c"

    allocArg ((_, tau), _) =
        faildoc $ text "Cannot allocate argument of type" <+> ppr tau

-- | Allocate space for a temporary value
allocTemp :: Rho -> C CExp
allocTemp (ScalarT tau) = do
    v <- gensym "temp"
    addLocal [$cdecl|$ty:cty $id:v;|]
    return $ ScalarCExp [$cexp|$id:v|]
  where
    cty :: C.Type
    cty = baseTypeToC tau

allocTemp (VectorT tau n) = do
    v  <- gensym "temp"
    vn <- gensym "tempn"
    addDevAlloc DevAlloc  {  devAllocVar    = v
                          ,  devAllocParams = [ [$cparam|$ty:cty* $id:v|],
                                                [$cparam|long long* $id:vn|] ]
                          ,  devAllocType   = VectorT tau n
                          }
    return $ VectorCExp [$cexp|$id:v|] [$cexp|*$id:vn|]
  where
    cty :: C.Type
    cty = baseTypeToC tau

allocTemp (MatrixT tau s r c) = do
    v <- gensym "temp"
    addDevAlloc DevAlloc  {  devAllocVar    = v
                          ,  devAllocParams = [ [$cparam|$ty:cty* $id:v|] ]
                          ,  devAllocType   = MatrixT tau s r c
                          }
    return $ MatrixCExp [$cexp|$id:v|] s r c
  where
    cty :: C.Type
    cty = baseTypeToC tau

allocTemp tau =
    faildoc $ text "Cannot allocate temporary of type" <+> ppr tau

-- | Allocate device memory for a function result (if needed) and return a list
-- of variables that make up the result. For a scalar result, this actually
-- forces the allocation of device memory. For other types, we collect the names
-- of the already allocated temporaries that are part of the result.
allocResult :: Rho -> CExp -> C [String]
allocResult (ScalarT UnitT) _ =
    return []

allocResult (ScalarT tau) (ScalarCExp ce) = do
    v <- gensym "result"
    addStm [$cstm|*$id:v = $ce;|]
    addDevAlloc DevAlloc  {  devAllocVar    = v
                          ,  devAllocParams = [ [$cparam|$ty:cty* $id:v|] ]
                          ,  devAllocType   = ScalarT tau
                          }
    return [v]
  where
    cty :: C.Type
    cty = baseTypeToC tau

allocResult (VectorT {}) (VectorCExp (C.Var (C.Id v _) _) _) =
    return [v]

allocResult (MatrixT {}) (MatrixCExp (C.Var (C.Id v _) _) _ _ _) =
    return [v]

allocResult tau ce =
    faildoc $  text "allocResult: type mismatch between expression" <+>
               ppr ce <+> text "and type" <+> ppr tau

-- | Figure out the proper way to return a result for an on-device function
-- call. If the result is a scalar, we return it from the function. Otherwise
-- the result is stored in allocated device memory, so we don't need to return
-- anything. We return a pair consisting of the function's return type and the
-- list of variables that make up the result.
returnResult :: Rho -> CExp -> C (C.Type, [String])
returnResult (ScalarT tau) (ScalarCExp ce) = do
    addStm [$cstm|return $ce;|]
    return (baseTypeToC tau, [])

returnResult (VectorT {}) (VectorCExp (C.Var (C.Id v _) _) _) =
    return ([$cty|void|], [v])

returnResult (MatrixT {}) (MatrixCExp (C.Var (C.Id v _) _) _ _ _) =
    return ([$cty|void|], [v])

returnResult tau ce =
    faildoc $  text "returnResult: type mismatch between expression" <+>
               ppr ce <+> text "and type" <+> ppr tau

parfor :: Ctx
       -> String         -- ^ Suggested name of the index variable
       -> N              -- ^ Iterate over 0..N-1
       -> (C.Exp -> C a) -- ^ Continuation (passed the loop index)
       -> C a
parfor ctx v n cont = do
    v'        <- gensym v
    ce        <- evalN n
    (x, body) <- inNewBlock $
                 cont [$cexp|$id:v'|]
    withGridVar ctx n $ \maybe_g ->
        case maybe_g of
          Just g ->  gridParfor g v' ce [$cstm|{ $items:body }|]
          Nothing -> withBlockVar ctx $ \maybe_t ->
                         threadParfor maybe_t v' ce [$cstm|{ $items:body }|]
    return x
  where
    gridParfor :: GridVar -> String -> C.Exp -> C.Stm -> C ()
    gridParfor g v n body = do
        addLocal [$cdecl|const int $id:v = $g;|]
        addStm [$cstm|if ($id:v < $n) $stm:body|]

    threadParfor :: Maybe BlockVar -> String -> C.Exp -> C.Stm -> C ()
    threadParfor Nothing v n body = do
        addStm [$cstm|for (int $id:v = 0; $id:v < $n; ++$id:v)
                          $stm:body |]

    threadParfor(Just t)  v n body = do
        vs <- gensym (v ++ "s")
        addStm [$cstm|for (int $id:vs = 0; $id:vs < $n; $id:vs += $(blockWidth t)) {
                          const int $id:v = $id:vs + $t;
                          if ($id:v < $n) $stm:body
                      }|]

-- | Compile an 'Exp' to a 'CExp'
compileExp :: Ctx -> DExp -> C CExp
compileExp _ (VarE v) =
    lookupVarExp v

compileExp _ (DelayedE _) =
    fail "Cannot compile delayed expression"

compileExp ctx (LetE v@(Var vname) tau e1 e2) = do
    cve <- compileExp (nest ctx) e1 >>= compileLet tau
    extendVars    [(v, tau)] $ do
    extendVarExps [(v, cve)] $ do
    compileExp (nest ctx) e2
  where
    compileLet :: Rho -> CExp -> C CExp
    compileLet (ScalarT _) ce@(ScalarCExp [$cexp|$id:_|]) = do
        return ce

    compileLet (ScalarT tau) (ScalarCExp ce1) = do
        addLocal [$cdecl|$ty:cty $id:vname;|]
        addStm [$cstm|$id:vname = $ce1;|]
        return $ ScalarCExp [$cexp|$id:vname|]
      where
        cty :: C.Type
        cty = baseTypeToC tau

    compileLet (VectorT {}) v@(VectorCExp {}) =
        return v

    compileLet (MatrixT {}) m@(MatrixCExp {}) =
        return m

    compileLet (FunT {}) f@(FunCExp {}) =
        return f

    compileLet tau ce = faildoc $
        text "let: type mismatch between expression" <+>
        ppr ce <+> text "and type" <+> ppr tau

compileExp _ (LamE vrhos body) = do
    fname <- gensym "f"
    ce    <- compileFun fname vrhos body
    return ce

compileExp ctx (AppE f es) = do
    FunCExp fname tau tempAllocs resultAllocs <- compileF f
    taus         <- mapM check es
    let phi      =  match taus
    explicitArgs <- mapM (compileExp ctx) es >>= mapM toArgs >>= return . concat
    tempArgs     <- mapM (allocTemp . phi . devAllocType) tempAllocs >>=
                    mapM toTempArgs >>= return . concat
    results      <- mapM (allocTemp . phi . devAllocType) resultAllocs
    resultArgs   <- mapM toTempArgs results >>= return . concat
    case tau of
      ScalarT {} -> do  temp <- gensym "temp"
                        addLocal [$cdecl|$ty:(typeToC tau) $id:temp;|]
                        addStm [$cstm|$id:temp = $id:fname($args:explicitArgs,
                                                           $args:tempArgs,
                                                           $args:resultArgs);|]
                        toCExp [$cexp|$id:temp|] tau
      _ -> do  let [ce] = results
               addStm [$cstm|$id:fname($args:explicitArgs,
                                       $args:tempArgs,
                                       $args:resultArgs);|]
               return ce
  where
    compileF :: DExp -> C CExp
    compileF f = do
        cf <- compileExp ctx f
        case cf of
          FunCExp {} -> return cf
          _ -> fail "Cannot apply non-function"

    toCExp :: C.Exp -> Rho -> C CExp
    toCExp ce (ScalarT _)       = return $ ScalarCExp ce
    toCExp ce (VectorT _ n)     = VectorCExp ce <$> evalN n
    toCExp ce (MatrixT _ s r c) = return $ MatrixCExp ce s r c
    toCExp _  (FunT {})         = fail "Function cannot return a function type"

compileExp _ (BoolE False) = return (ScalarCExp [$cexp|0|])
compileExp _ (BoolE True)  = return (ScalarCExp [$cexp|1|])

compileExp _ (IntE n) =
    return (ScalarCExp [$cexp|$int:i|])
  where
    i :: Integer
    i = toInteger n

compileExp _ (FloatE n) =
    return (ScalarCExp [$cexp|$float:r|])
  where
    r :: Rational
    r = toRational n

compileExp ctx (UnopE op e) = do
    ce <- compileExp (nest ctx) e >>= fromScalar
    return $ ScalarCExp (compile op ce)
  where
    fromScalar :: CExp -> C C.Exp
    fromScalar (ScalarCExp ce) = return ce
    fromScalar cexp =
        faildoc $
        text "Type mismatch: cannot apply unary operator" <+>
        ppr op <+> text "to" <+> ppr cexp

    compile :: Unop -> C.Exp -> C.Exp
    compile Lnot e = [$cexp|!$e|]

    compile Ineg e    = [$cexp|- $e|]
    compile Iabs e    = [$cexp|abs($e)|]
    compile Isignum e = [$cexp|$e > 0 ? 1 : ($e < 0 ? -1 : 0)|]

    compile Fneg e    = [$cexp|- $e|]
    compile Fabs e    = [$cexp|fabsf($e)|]
    compile Fsignum e = [$cexp|$e > 0 ? 1 : ($e < 0 ? -1 : 0)|]

    compile Fexp e   = [$cexp|expf($e)|]
    compile Fsqrt e  = [$cexp|sqrtf($e)|]
    compile Flog e   = [$cexp|logf($e)|]
    compile Fsin e   = [$cexp|sinf($e)|]
    compile Ftan e   = [$cexp|tanf($e)|]
    compile Fcos e   = [$cexp|cosf($e)|]
    compile Fasin e  = [$cexp|asinf($e)|]
    compile Fatan e  = [$cexp|atanf($e)|]
    compile Facos e  = [$cexp|acosf($e)|]
    compile Fsinh e  = [$cexp|asinh($e)|]
    compile Ftanh e  = [$cexp|atanh($e)|]
    compile Fcosh e  = [$cexp|acosh($e)|]
    compile Fasinh e = [$cexp|asinh($e)|]
    compile Fatanh e = [$cexp|atanh($e)|]
    compile Facosh e = [$cexp|acosh($e)|]

compileExp ctx (BinopE op e1 e2) = do
    ce1 <- compileExp (nest ctx) e1 >>= fromScalar
    ce2 <- compileExp (nest ctx) e2 >>= fromScalar
    return $ ScalarCExp (compile op ce1 ce2)
  where
    fromScalar :: CExp -> C C.Exp
    fromScalar (ScalarCExp ce) = return ce
    fromScalar cexp =
        faildoc $
        text "Type mismatch: cannot apply binary operator" <+>
        ppr op <+> text "to" <+> ppr cexp

    compile :: Binop -> C.Exp -> C.Exp -> C.Exp
    compile Land e1 e2 = [$cexp|$e1 && $e2|]
    compile Lor e1 e2  = [$cexp|$e1 || $e2|]

    compile Leq e1 e2 = [$cexp|$e1 == $e2|]
    compile Lne e1 e2 = [$cexp|$e1 != $e2|]
    compile Lgt e1 e2 = [$cexp|$e1 > $e2|]
    compile Lge e1 e2 = [$cexp|$e1 >= $e2|]
    compile Llt e1 e2 = [$cexp|$e1 < $e2|]
    compile Lle e1 e2 = [$cexp|$e1 <= $e2|]

    compile Band e1 e2 = [$cexp|$e1 & $e2|]

    compile Iadd e1 e2 = [$cexp|$e1 + $e2|]
    compile Isub e1 e2 = [$cexp|$e1 - $e2|]
    compile Imul e1 e2 = [$cexp|$e1 * $e2|]
    compile Idiv e1 e2 = [$cexp|$e1 / $e2|]

    compile Fadd e1 e2 = [$cexp|$e1 + $e2|]
    compile Fsub e1 e2 = [$cexp|$e1 - $e2|]
    compile Fmul e1 e2 = [$cexp|$e1 * $e2|]
    compile Fdiv e1 e2 = [$cexp|$e1 / $e2|]

    compile Fpow e1 e2     = [$cexp|powf($e1, $e2)|]
    compile FlogBase e1 e2 = [$cexp|logf($e2)/logf($e1)|]

compileExp ctx (IfteE teste thene elsee) = do
    testce <- compileExp (nest ctx) teste
    (thence, thenItems) <- inNewBlock $
                           compileExp (nest ctx) thene
    (elsece, elseItems) <- inNewBlock $
                           compileExp (nest ctx) elsee
    tau      <- check thene
    result   <- allocTemp tau
    addStm [$cstm|if ($testce) {
                      $items:thenItems
                      $result = $thence;
                  } else {
                      $items:elseItems
                      $result = $elsece;
                  } |]
    return result

compileExp ctx e@(MapE (LamE [(x, _)] body) e1) = do
    rho@(VectorT _ n) <- check e
    (tau1, _)         <- checkVector e1
    result            <- allocTemp rho
    cn :: C.Exp       <- evalN n
    cx                <- compileExp (nest ctx) e1
    (fapp, items) <-
        extendVars    [(x, ScalarT tau1)] $
        extendVarExps [(x, ScalarCExp [$cexp|$cx[i]|])] $
        inNewBlock $
        compileExp (nest ctx) body
    parfor ctx "i" n $ \i -> do
        addStm [$cstm|{$items:items $result[$i] = $fapp; }|]
        addStm [$cstm|if ($i == 0) $(vectorSize result) = $cn;|]
    addStm [$cstm|__syncthreads();|]
    return result

compileExp _ (MapE {}) =
    fail "Impossible: improperly reified map expression"

compileExp ctx (MapME (LamE [(x, rho)] body) xs ys) = do
    (VectorT _ n1) <- check xs
    (VectorT _ n2) <- check ys
    let n          =  NMin [n1, n2]
    cxs            <- compileExp (nest ctx) xs
    cys            <- compileExp (nest ctx) ys
    (fapp, items) <-
        extendVars    [(x, rho)] $
        extendVarExps [(x, ScalarCExp [$cexp|$cxs[i]|])] $
        inNewBlock $
        compileExp (nest ctx) body
    parfor ctx "i" n $ \i -> do
        addStm [$cstm|{$items:items $cys[$i] = $fapp; }|]
    addStm [$cstm|__syncthreads();|]
    return $ error "mapM returns unit"

compileExp _ (MapME {}) =
    fail "Impossible: improperly reified mapM expression"

compileExp ctx e@(PermuteE xs is) = do
    rho@(VectorT _ n) <- check e
    cys               <- allocTemp rho
    cn :: C.Exp       <- evalN n
    cxs               <- compileExp (nest ctx) xs
    cis               <- compileExp (nest ctx) is
    parfor ctx "i" n $ \i -> do
        addStm [$cstm|{
                   $cys[$cis[$i]] = $cxs[$i];
                   if ($i == 0)
                       $(vectorSize cys) = $cn;
               }|]
    addStm [$cstm|__syncthreads();|]
    return cys

compileExp ctx (PermuteME xs is ys) = do
    (VectorT _ n1) <- check xs
    (VectorT _ n2) <- check is
    (VectorT _ n3) <- check ys
    let n          =  NMin [n1, n2, n3]
    cxs            <- compileExp (nest ctx) xs
    cis            <- compileExp (nest ctx) is
    cys            <- compileExp (nest ctx) ys
    parfor ctx "i" n $ \i -> do
        addStm [$cstm|{
                   $cys[$cis[$i]] = $cxs[$i];
               }|]
    addStm [$cstm|__syncthreads();|]
    return $ error "permuteM returns unit"

compileExp ctx e@(ZipWithE (LamE [(x, _), (y, _)] body) e1 e2) = do
    rho@(VectorT _ n) <- check e
    (tau1, _)         <- checkVector e1
    (tau2, _)         <- checkVector e2
    result            <- allocTemp rho
    cn :: C.Exp       <- evalN n
    cx                <- compileExp (nest ctx) e1
    cy                <- compileExp (nest ctx) e2
    (fapp, items) <-
        extendVars    [(x, ScalarT tau1),
                       (y, ScalarT tau2)] $
        extendVarExps [(x, ScalarCExp [$cexp|$cx[i]|]),
                       (y, ScalarCExp [$cexp|$cy[i]|])] $
        inNewBlock $
        compileExp (nest ctx) body
    parfor ctx "i" n $ \i -> do
        addStm [$cstm|{$items:items $result[$i] = $fapp; }|]
        addStm [$cstm|if ($i == 0) $(vectorSize result) = $cn;|]
    addStm [$cstm|__syncthreads();|]
    return result

compileExp _ (ZipWithE {}) =
    fail "Impossible: improperly reified zipWith expression"

compileExp ctx e@(ZipWith3E (LamE [(x, _), (y, _), (z, _)] body) e1 e2 e3) = do
    rho@(VectorT _ n) <- check e
    (tau1, _)         <- checkVector e1
    (tau2, _)         <- checkVector e2
    (tau3, _)         <- checkVector e3
    result            <- allocTemp rho
    cn :: C.Exp       <- evalN n
    cx                <- compileExp (nest ctx) e1
    cy                <- compileExp (nest ctx) e2
    cz                <- compileExp (nest ctx) e3
    (fapp, items) <-
        extendVars    [(x, ScalarT tau1),
                       (y, ScalarT tau2),
                       (z, ScalarT tau3)] $
        extendVarExps [(x, ScalarCExp [$cexp|$cx[i]|]),
                       (y, ScalarCExp [$cexp|$cy[i]|]),
                       (z, ScalarCExp [$cexp|$cz[i]|])] $
        inNewBlock $
        compileExp (nest ctx) body
    parfor ctx "i" n $ \i -> do
        addStm [$cstm|{$items:items $result[$i] = $fapp; }|]
        addStm [$cstm|if ($i == 0) $(vectorSize result) = $cn;|]
    addStm [$cstm|__syncthreads();|]
    return result

compileExp _ (ZipWith3E {}) =
    fail "Impossible: improperly reified zipWith3 expression"

compileExp ctx (ZipWith3ME (LamE [(x, _), (y, _), (z, _)] body) xs ys zs results) = do
    (VectorT tau1 n1) <- check xs
    (VectorT tau2 n2) <- check ys
    (VectorT tau3 n3) <- check zs
    (VectorT _ n4)    <- check results
    let n             =  NMin [n1, n2, n3, n4]
    cxs               <- compileExp (nest ctx) xs
    cys               <- compileExp (nest ctx) ys
    czs               <- compileExp (nest ctx) zs
    cresults          <- compileExp (nest ctx) results
    (fapp, items) <-
        extendVars    [(x, ScalarT tau1),
                       (y, ScalarT tau2),
                       (z, ScalarT tau3)] $
        extendVarExps [(x, ScalarCExp [$cexp|$cxs[i]|]),
                       (y, ScalarCExp [$cexp|$cys[i]|]),
                       (z, ScalarCExp [$cexp|$czs[i]|])] $
        inNewBlock $
        compileExp (nest ctx) body
    parfor ctx "i" n $ \i -> do
        addStm [$cstm|{$items:items $cresults[$i] = $fapp; }|]
    addStm [$cstm|__syncthreads();|]
    return $ error "zipWith3M returns unit"

compileExp _ (ZipWith3ME {}) =
    fail "Impossible: improperly reified zipWith3M expression"

compileExp ctx e@(ScanE (LamE [(x, _), (y, _)] body) z xs) = do
    rho@(VectorT tau n) <- check e
    result              <- allocTemp rho
    let ctau            =  baseTypeToC tau
    cn :: C.Exp         <- evalN n
    cz                  <- compileExp (nest ctx) z
    cxs                 <- compileExp (nest ctx) xs
    temp                <- gensym "temp"
    t                   <- gensym "t"
    addLocal [$cdecl|__shared__ $ty:ctau $id:temp[2*$int:threadBlockWidth];|]
    parfor ctx "i" ((n+1) `div` 2) $ \i -> do
        (sum1, items1) <- plus tau [$cexp|$id:temp[ai]|] [$cexp|$id:temp[bi]|]
        (sum2, items2) <- plus tau [$cexp|$id:temp[bi]|] [$cexp|$id:t|]
        addStm [$cstm|{
            int offset = 1;

            $id:temp[2*$i]   = $cxs[2*$i];
            $id:temp[2*$i+1] = $cxs[2*$i+1];

            for (int d = $cn>>1; d > 0; d >>= 1) {
                __syncthreads();

                if ($i < d) {
                    int ai = offset*(2*$i+1)-1;
                    int bi = offset*(2*$i+2)-1;

                    $items:items1
                    $id:temp[bi] = $sum1;
                }
                offset *= 2;
            }

            if ($i == 0)
                $id:temp[$cn-1] = $cz;

            for (int d = 1; d < $cn; d *= 2) {
                offset >>= 1;
                __syncthreads();

                if ($i < d) {
                    int ai = offset*(2*$i+1)-1;
                    int bi = offset*(2*$i+2)-1;

                    $ty:ctau $id:t;

                    $items:items2

                    $id:t        = $id:temp[ai];
                    $id:temp[ai] = $id:temp[bi];
                    $id:temp[bi] = $sum2;
                }
            }

            __syncthreads();

            $result[2*$i]   = $id:temp[2*$i];
            $result[2*$i+1] = $id:temp[2*$i+1];

            if ($i == 0)
                $(vectorSize result) = $cn;
          }|]
    addStm [$cstm|__syncthreads();|]
    return result
  where
    plus :: Tau -> C.Exp -> C.Exp -> C (CExp, [C.BlockItem])
    plus tau e1 e2 =
        extendVars    [(x, ScalarT tau),
                       (y, ScalarT tau)] $
        extendVarExps [(x, ScalarCExp e1),
                       (y, ScalarCExp e2)] $
        inNewBlock $
        compileExp (nest ctx) body

compileExp _ (ScanE {}) =
    fail "Impossible: improperly reified scan expression"

compileExp ctx e@(BlockedScanME (LamE [(x, _), (y, _)] body) z xs) = do
    (VectorT tau n)       <- check xs
    rho@(VectorT _ sumsn) <- check e
    sums                  <- allocTemp rho
    let ctau              =  baseTypeToC tau
    cn :: C.Exp           <- evalN n
    csumsn :: C.Exp       <- evalN sumsn
    cz                    <- compileExp (nest ctx) z
    cxs                   <- compileExp (nest ctx) xs
    temp                  <- gensym "temp"
    addLocal [$cdecl|__shared__ $ty:ctau $id:temp[2*$int:threadBlockWidth];|]
    parfor ctx "i" ((n+1) `div` 2) $ \i -> do
        (sum1, items1) <- plus tau [$cexp|$id:temp[ai]|] [$cexp|$id:temp[bi]|]
        (sum2, items2) <- plus tau [$cexp|$id:temp[bi]|] [$cexp|t|]
        addStm [$cstm|{
            int offset = 1;
            int block = 2*blockIdx.x*$int:threadBlockWidth;
            int tid = threadIdx.x;
            int n;

            if ($cn > 2*$int:threadBlockWidth)
                n = 2*$int:threadBlockWidth;
            else
                n = $cn;

            $id:temp[2*tid]   = $cxs[block + 2*tid];
            $id:temp[2*tid+1] = $cxs[block + 2*tid+1];

            for (int d = n>>1; d > 0; d >>= 1) {
                __syncthreads();

                if (tid < d) {
                    int ai = offset*(2*tid+1)-1;
                    int bi = offset*(2*tid+2)-1;

                    $items:items1
                    $id:temp[bi] = $sum1;
                }
                offset *= 2;
            }

            __syncthreads();

            if (threadIdx.x == 0) {
                if (gridDim.x > 1)
                    $sums[blockIdx.x] = $id:temp[n-1];
                $id:temp[n-1] = $cz;
            }

            for (int d = 1; d < n; d *= 2) {
                offset >>= 1;
                __syncthreads();

                if (tid < d) {
                    int ai = offset*(2*tid+1)-1;
                    int bi = offset*(2*tid+2)-1;

                    $ty:ctau t;

                    $items:items2

                    t            = $id:temp[ai];
                    $id:temp[ai] = $id:temp[bi];
                    $id:temp[bi] = $sum2;
                }
            }

            __syncthreads();

            $cxs[block + 2*tid]   = $id:temp[2*tid];
            $cxs[block + 2*tid+1] = $id:temp[2*tid+1];

            if ($i == 0)
                $(vectorSize sums) = $csumsn;
          }|]
    return sums
  where
    plus :: Tau -> C.Exp -> C.Exp -> C (CExp, [C.BlockItem])
    plus tau e1 e2 =
        extendVars    [(x, ScalarT tau),
                       (y, ScalarT tau)] $
        extendVarExps [(x, ScalarCExp e1),
                       (y, ScalarCExp e2)] $
        inNewBlock $
        compileExp (nest ctx) body

compileExp _ (BlockedScanME {}) =
    fail "Impossible: improperly reified upsweep expression"

compileExp ctx e@(BlockedNacsME (LamE [(x, _), (y, _)] body) z xs) = do
    (VectorT tau n)       <- check xs
    rho@(VectorT _ sumsn) <- check e
    sums                  <- allocTemp rho
    let ctau              =  baseTypeToC tau
    cn :: C.Exp           <- evalN n
    csumsn :: C.Exp       <- evalN sumsn
    cz                    <- compileExp (nest ctx) z
    cxs                   <- compileExp (nest ctx) xs
    temp                  <- gensym "temp"
    addLocal [$cdecl|__shared__ $ty:ctau $id:temp[2*$int:threadBlockWidth];|]
    parfor ctx "i" ((n+1) `div` 2) $ \i -> do
        (sum1, items1) <- plus tau [$cexp|$id:temp[ai]|] [$cexp|$id:temp[bi]|]
        (sum2, items2) <- plus tau [$cexp|$id:temp[bi]|] [$cexp|t|]
        addStm [$cstm|{
            int offset = 1;
            int block = 2*blockIdx.x*$int:threadBlockWidth;
            int tid = threadIdx.x;
            int n;

            if ($cn > 2*$int:threadBlockWidth)
                n = 2*$int:threadBlockWidth;
            else
                n = $cn;

            $id:temp[2*tid]   = $cxs[block + 2*tid];
            $id:temp[2*tid+1] = $cxs[block + 2*tid+1];

            for (int d = n>>1; d > 0; d >>= 1) {
                __syncthreads();

                if (tid < d) {
                    int ai = n-1-(offset*(2*tid+1)-1);
                    int bi = n-1-(offset*(2*tid+2)-1);

                    $items:items1
                    $id:temp[bi] = $sum1;
                }
                offset *= 2;
            }

            __syncthreads();

            if (threadIdx.x == 0) {
                if (gridDim.x > 1)
                    $sums[blockIdx.x] = $id:temp[0];
                $id:temp[0] = $cz;
            }

            for (int d = 1; d < n; d *= 2) {
                offset >>= 1;
                __syncthreads();

                if (tid < d) {
                    int ai = n-1-(offset*(2*tid+1)-1);
                    int bi = n-1-(offset*(2*tid+2)-1);

                    $ty:ctau t;

                    $items:items2

                    t            = $id:temp[ai];
                    $id:temp[ai] = $id:temp[bi];
                    $id:temp[bi] = $sum2;
                }
            }

            __syncthreads();

            $cxs[block + 2*tid]   = $id:temp[2*tid];
            $cxs[block + 2*tid+1] = $id:temp[2*tid+1];

            if ($i == 0)
                $(vectorSize sums) = $csumsn;
          }|]
    return sums
  where
    plus :: Tau -> C.Exp -> C.Exp -> C (CExp, [C.BlockItem])
    plus tau e1 e2 =
        extendVars    [(x, ScalarT tau),
                       (y, ScalarT tau)] $
        extendVarExps [(x, ScalarCExp e1),
                       (y, ScalarCExp e2)] $
        inNewBlock $
        compileExp (nest ctx) body

compileExp _ (BlockedNacsME {}) =
    fail "Impossible: improperly reified blockedNacsM expression"

compileExp ctx (BlockedAddME xs sums) = do
    VectorT _ n <- check xs
    cxs         <- compileExp (nest ctx) xs
    csums       <- compileExp (nest ctx) sums
    parfor ctx "i" ((n+1) `div` 2) $ \_ -> do
        addStm [$cstm|{
            int block = 2*blockIdx.x*$int:threadBlockWidth;
            int tid = threadIdx.x;

            if (blockIdx.x > 0) {
                $cxs[block + 2*tid]   = $cxs[block + 2*tid] + $csums[blockIdx.x];
                $cxs[block + 2*tid+1] = $cxs[block + 2*tid+1] + $csums[blockIdx.x];
            }
          }|]
    return (error "blockedadd returns unit")

compileFunBody :: Ctx
               -> [(Var, Rho)]
               -> DExp
               -> ((Rho, CExp) -> C a)
               -> C (a, [C.Param], [C.BlockItem])
compileFunBody ctx vrhos body cont =
    inNewFunction $ do
    inNewCompiledFunction $ do
    vexps <- allocArgs vrhos
    (tau, ce) <- extendVars vrhos $ do
                 extendVarExps (vs `zip` vexps) $ do
                 tau <- check body
                 ce  <- compileExp ctx body
                 return (tau, ce)
    cont (tau, ce)
  where
    vs :: [Var]
    vs = map fst vrhos

orderFunAllocs :: [String] -> C ([DevAlloc], [DevAlloc])
orderFunAllocs results = do
    allocs <- getDevAllocs
    let (tempAllocs, resultAllocs) = orderAllocs results allocs
    forM_ tempAllocs $ \alloc -> mapM_ addParam (devAllocParams alloc)
    forM_ resultAllocs $ \alloc -> mapM_ addParam (devAllocParams alloc)
    return (tempAllocs, resultAllocs)
  where
    orderAllocs :: [String] -> [DevAlloc] -> ([DevAlloc], [DevAlloc])
    orderAllocs results allocs =
        (tempAllocs, resultAllocs)
      where
        tempAllocs :: [DevAlloc]
        tempAllocs = [alloc | alloc <- allocs,
                              devAllocVar alloc `notElem` results]

        resultAllocs :: [DevAlloc]
        resultAllocs = map findAlloc results
          where
            findAlloc :: String -> DevAlloc
            findAlloc v = fromJust $ find (\alloc -> devAllocVar alloc == v) allocs

compileFun :: String -> [(Var, Rho)] -> DExp -> C CExp
compileFun fname vrhos body = do
    ((cty, tau, tempAllocs, resultAllocs), ps, items) <-
      compileFunBody (NestedFun 0) vrhos body $ \(tau, ce) -> do
        (cty, results)             <- returnResult tau ce
        (tempAllocs, resultAllocs) <- orderFunAllocs results
        return (cty, tau, tempAllocs, resultAllocs)

    addGlobal [$cedecl|__device__ $ty:cty $id:fname($params:ps)
                       { $items:items }
                      |]

    return $ FunCExp fname tau tempAllocs resultAllocs

-- | Compile a 'Fun' to a 'CFun'
compileTopFun :: String -> DExp -> IO (CFun a)
compileTopFun fname (LamE vrhos body) =
    runCFun compile
  where
    compile :: C (String, [DevAlloc])
    compile = do
        addSymbol fname
        ((tempAllocs, resultAllocs), ps, items) <-
          compileFunBody (TopFun 0) vrhos body $ \(tau, ce) -> do
            results <- allocResult tau ce
            orderFunAllocs results

        addGlobal [$cedecl|extern "C" __global__ void $id:fname($params:ps)
                           { $items:items }
                          |]

        return (fname, tempAllocs ++ resultAllocs)

compileTopFun _ e =
    faildoc $ text "Cannot compile non-function:" <+/> ppr e
