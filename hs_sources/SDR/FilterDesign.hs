{-| Filter design and plotting of frequency responses. -}

module SDR.FilterDesign (
    -- * Sinc Function
    sinc,

    -- * Windows
    hanning,
    hamming,
    blackman,
    
    -- * Frequency Response Plot
    plotFrequency
    ) where

import Graphics.Rendering.Chart.Easy
import Graphics.Rendering.Chart.Backend.Cairo
import Data.Complex

import qualified Data.Vector.Generic as VG

-- | Compute a sinc function
sinc :: (Floating n, VG.Vector v n)
     => Int -- ^ The length. Must be odd.
     -> n   -- ^ The cutoff frequency (from 0 to 1)
     -> v n
sinc size cutoff  = VG.generate size (func . (-) ((size - 1) `quot` 2))
    where
    func 0   = cutoff
    func idx = sin (pi * cutoff * fromIntegral idx) / (fromIntegral idx * pi)

-- | Compute a Hanning window.
hanning :: (Floating n, VG.Vector v n) 
        => Int -- ^ The length of the window
        -> v n
hanning size = VG.generate size func
    where
    func idx = 0.5 * (1 - cos((2 * pi * fromIntegral idx) / (fromIntegral size - 1)))
  
-- | Compute a Hamming window. 
hamming :: (Floating n, VG.Vector v n) 
        => Int -- ^ The length of the window
        -> v n
hamming size = VG.generate size func
    where
    func idx = 0.54 - 0.46 * cos((2 * pi * fromIntegral idx) / (fromIntegral size - 1))
   
-- | Compute a Blackman window.
blackman :: (Floating n, VG.Vector v n) 
        => Int -- ^ The length of the window
        -> v n
blackman size = VG.generate size func
    where
    func idx = 0.42 - 0.5 * cos((2 * pi * fromIntegral idx) / (fromIntegral size - 1)) + 0.08 * cos((4 * pi * fromIntegral idx) / (fromIntegral size - 1))

signal :: [Double] -> [Double] -> [(Double, Double)]
signal coeffs xs = [ (x / pi, func x) | x <- xs ]
    where
    func phase = magnitude $ sum $ zipWith (\index mag -> mkPolar mag (phase * (- index))) (iterate (+ 1) (- ((fromIntegral (length coeffs) - 1) / 2))) coeffs

-- | Given filter coefficients, plot their frequency response and save the graph as "frequency_response.png".
plotFrequency :: [Double] -- ^ The filter coefficients
              -> IO ()
plotFrequency coeffs = toFile def "frequency_response.png" $ do
    layout_title .= "Frequency Response"
    plot (line "Frequency Response" [signal coeffs $ takeWhile (< pi) $ iterate (+ 0.01) 0])
