{-# LANGUAGE FlexibleContexts, BangPatterns, ScopedTypeVariables, MultiParamTypeClasses, FlexibleInstances #-}

module SDR.Util (
    makeComplexBufferVect,
    convertC, 
    convertCSSE,
    convertCAVX,
    Mult,
    mult,
    parseSize,
    scaleC,
    scaleCSSE,
    scaleCAVX
    ) where

import Control.Monad
import Foreign.C.Types
import Foreign.ForeignPtr
import Foreign.Storable
import Data.Complex
import Data.ByteString.Internal 
import Data.ByteString as BS
import System.IO
import Data.Vector.Generic                         as VG   hiding ((++))
import qualified Data.Vector.Generic.Mutable       as VGM
import Data.Vector.Storable                        as VS   hiding ((++))
import Data.Vector.Storable.Mutable                as VSM  hiding ((++))
import Data.Vector.Fusion.Stream.Monadic                   hiding ((++))
import qualified Data.Vector.Fusion.Stream         as VFS  hiding ((++))
import qualified Data.Vector.Fusion.Stream.Monadic as VFSM hiding ((++))
import Data.Tuple.All
import Control.Monad.Primitive
import Control.Applicative
import Unsafe.Coerce
import Foreign.Ptr
import System.IO.Unsafe
import Foreign.Storable.Complex

import Pipes
import qualified Pipes.Prelude as P
import qualified Pipes.ByteString as PB
import Data.Serialize hiding (Done)
import qualified Data.Serialize as S
import Options.Applicative
import Data.Decimal

{-| Create a vector of complex samples from a vector of interleaved
    I Q components.
-}
{-# INLINE makeComplexBufferVect #-}
makeComplexBufferVect :: (Num a, Integral a, Num b, Fractional b, VG.Vector v1 a, VG.Vector v2 (Complex b)) => Int -> v1 a -> v2 (Complex b)
makeComplexBufferVect samples input = VG.generate samples convert
    where
    {-# INLINE convert #-}
    convert idx  = convert' (input `VG.unsafeIndex` (2 * idx)) :+ convert' (input `VG.unsafeIndex` (2 * idx + 1))
    {-# INLINE convert' #-}
    convert' val = (fromIntegral val - 128) / 128

foreign import ccall unsafe "convertC"
    convertC_c :: CInt -> Ptr CUChar -> Ptr CFloat -> IO ()

convertC :: Int -> VS.Vector CUChar -> VS.Vector (Complex Float)
convertC num inBuf = unsafePerformIO $ do
    outBuf <- VGM.new num
    VS.unsafeWith inBuf $ \iPtr -> 
        VSM.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            convertC_c (2 * fromIntegral num) iPtr oPtr
    VG.freeze outBuf

foreign import ccall unsafe "convertCSSE"
    convertCSSE_c :: CInt -> Ptr CUChar -> Ptr CFloat -> IO ()

convertCSSE :: Int -> VS.Vector CUChar -> VS.Vector (Complex Float)
convertCSSE num inBuf = unsafePerformIO $ do
    outBuf <- VGM.new num
    VS.unsafeWith inBuf $ \iPtr -> 
        VSM.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            convertCSSE_c (2 * fromIntegral num) iPtr oPtr
    VG.freeze outBuf

foreign import ccall unsafe "convertCAVX"
    convertCAVX_c :: CInt -> Ptr CUChar -> Ptr CFloat -> IO ()

convertCAVX :: Int -> VS.Vector CUChar -> VS.Vector (Complex Float)
convertCAVX num inBuf = unsafePerformIO $ do
    outBuf <- VGM.new num
    VS.unsafeWith inBuf $ \iPtr -> 
        VSM.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            convertCAVX_c (2 * fromIntegral num) iPtr oPtr
    VG.freeze outBuf

-- | A class for things that can be multiplied by a scalar.
class Mult a b where
    mult :: a -> b -> a

instance (Num a) => Mult a a where
    mult = (*)

instance (Num a) => Mult (Complex a) a where
    mult (x :+ y) z = (x * z) :+ (y * z)

parseSize :: ReadM Integer
parseSize = eitherReader $ \arg -> case reads arg of
    [(r, suffix)] -> case suffix of 
        []  -> return $ round (r :: Decimal)
        "K" -> return $ round $ r * 1000 
        "M" -> return $ round $ r * 1000000
        "G" -> return $ round $ r * 1000000000
        x   -> Left  $ "Cannot parse suffix: `" ++ x ++ "'"
    _             -> Left $ "Cannot parse value: `" ++ arg ++ "'"

-- | Scaling
foreign import ccall unsafe "scale"
    scale_c :: CInt -> CFloat -> Ptr CFloat -> Ptr CFloat -> IO ()

scaleC :: Int -> Float -> VS.Vector Float -> VS.MVector RealWorld Float -> IO ()
scaleC num factor inBuf outBuf = 
    VS.unsafeWith (unsafeCoerce inBuf) $ \iPtr -> 
        VS.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            scale_c (fromIntegral num) (unsafeCoerce factor) iPtr oPtr

foreign import ccall unsafe "scaleSSE"
    scaleSSE_c :: CInt -> CFloat -> Ptr CFloat -> Ptr CFloat-> IO ()

scaleCSSE :: Int -> Float -> VS.Vector Float -> VS.MVector RealWorld Float -> IO ()
scaleCSSE num factor inBuf outBuf = 
    VS.unsafeWith (unsafeCoerce inBuf) $ \iPtr -> 
        VS.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            scaleSSE_c (fromIntegral num) (unsafeCoerce factor) iPtr oPtr

foreign import ccall unsafe "scaleAVX"
    scaleAVX_c :: CInt -> CFloat -> Ptr CFloat -> Ptr CFloat -> IO ()

scaleCAVX :: Int -> Float -> VS.Vector Float -> VS.MVector RealWorld Float -> IO ()
scaleCAVX num factor inBuf outBuf = 
    VS.unsafeWith (unsafeCoerce inBuf) $ \iPtr -> 
        VS.unsafeWith (unsafeCoerce outBuf) $ \oPtr -> 
            scaleAVX_c (fromIntegral num) (unsafeCoerce factor) iPtr oPtr
