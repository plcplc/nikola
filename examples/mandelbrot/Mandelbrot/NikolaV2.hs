{-# LANGUAGe BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGe TemplateHaskell #-}

module Mandelbrot.NikolaV2
    ( mandelbrot
    , prettyMandelbrot
    ) where

import Control.Monad (replicateM_)

import Data.Array.Nikola.Backend.CUDA.TH
import Data.Array.Repa
import Data.Array.Repa.Mutable
import Data.Array.Repa.Repr.ForeignPtr
import Data.Array.Repa.Repr.UnboxedForeign
import Data.Array.Repa.Repr.CUDA.UnboxedForeign
import qualified Data.Vector.UnboxedForeign as VUF
import qualified Data.Vector.Storable as V

import qualified Mandelbrot.NikolaV2.Implementation as I
import Mandelbrot.Types

type MComplexPlane r = MArray r DIM2 Complex

type MStepPlane r = MArray r DIM2 (Complex, I)

step :: ComplexPlane CUF -> MStepPlane CUF -> IO ()
step = $(compile I.step)

genPlane :: R
         -> R
         -> R
         -> R
         -> I
         -> I
         -> MComplexPlane CUF
         -> IO ()
genPlane = $(compile I.genPlane)

mkinit :: ComplexPlane CUF -> MStepPlane CUF -> IO ()
mkinit = $(compile I.mkinit)

prettyMandelbrot :: I -> StepPlane CUF -> IO (Bitmap F)
prettyMandelbrot limit arr = do
    bmap                              <- prettyMandelbrotDev limit arr
    let AFUnboxed sh (VUF.V_Word32 v) =  toHostArray bmap
    let (fp, n)                       =  V.unsafeToForeignPtr0 v
    return $ AForeignPtr sh n fp
  where
    prettyMandelbrotDev :: I -> StepPlane CUF -> IO (Bitmap CUF)
    prettyMandelbrotDev = $(compile I.prettyMandelbrot)

mandelbrot :: R
           -> R
           -> R
           -> R
           -> I
           -> I
           -> I
           -> IO (StepPlane CUF)
mandelbrot lowx lowy highx highy viewx viewy depth = do
    mcs <- newMArray sh
    genPlane lowx lowy highx highy viewx viewy mcs
    cs  <- unsafeFreezeMArray mcs
    mzs <- newMArray sh
    mkinit cs mzs
    replicateM_ (fromIntegral depth) (step cs mzs)
    unsafeFreezeMArray mzs
  where
    sh :: DIM2
    sh = ix2 (fromIntegral viewy) (fromIntegral viewx)
