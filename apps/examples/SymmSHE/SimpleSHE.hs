{-# LANGUAGE
     DataKinds,         -- so we can use GHC.TypeLits
     KindSignatures,
     NoImplicitPrelude, -- an alternate Prelude is imported from Crypto.Lol
     RebindableSyntax,  -- since we use an alternate Prelude, this lets GHC read literals, etc
     ScopedTypeVariables,
     TemplateHaskell    -- provides a simple way to construct cyclotomic indices and prime-power moduli
     #-}

import Crypto.Lol hiding ((^),CT)
import qualified Crypto.Lol as Lol
import Crypto.Lol.Applications.SymmSHE
import Algebra.Ring ((^)) -- easier to use with the TH commands below
import Data.Int -- to use the CT backend, you must use Int64 rather than Int
import Math.NumberTheory.Primes.Testing (isPrime) -- used to generate "good" moduli
import Control.Monad.Random (getRandom)
import GHC.TypeLits (Nat)

-- an infinite list of primes greater than `lower` and congruent to 1 mod m
-- useful for generating moduli for CTZq below
goodQs :: (IntegralDomain i, ToInteger i) => i -> i -> [i]
goodQs m lower = checkVal (lower + ((m-lower) `mod` m) + 1)
  where checkVal v = if (isPrime (fromIntegral v :: Integer))
                     then v : checkVal (v+m)
                    else checkVal (v+m)

-- PTIndex must divide CTIndex
type PTIndex = F128
-- Crypto.Lol includes Factored types F1..F512
-- for cyclotomic indices outside this range,
-- we provide a TH wrapper.
-- TH to constuct the cyclotomic index 11648
type CTIndex = $(fType $ 2^7 * 7 * 13)
-- to use crtSet (for example, when ring switching), the plaintext modulus must be a PrimePower (ZPP constraint)
-- Crypto.Lol exports PP2,PP4,...,PP128 as well as some prime powers for 3,5,7, and 11.
-- See Crypto.Lol.Factored. Alternately, an arbitrary prime power p^e can be constructed with
-- the TH $(ppType (p,e))
-- for applications that don't use crtSet, PT modulus can be a TypeLit.
type PTZq = ZqBasic PP8 Int64
-- uses GHC.TypeLits as modulus, and Int64 as repr (needed to use with CT backend)
-- modulus doesn't have to be "good", but "good" moduli are much faster
type Zq (q :: Nat) = ZqBasic q Int64
type CTZq1 = Zq 536937857
type CTZq2 = (CTZq1, Zq 536972801)
type CTZq3 = (CTZq2, Zq 537054337)
-- Tensor backend, either Repa (RT) or C (CT)
type T = Lol.CT -- can also use RT

type KSGad = TrivGad -- can also use (BaseBGad 2), for example

type PTRing = Cyc T PTIndex PTZq
type CTRing1 = CT PTIndex PTZq (Cyc T CTIndex CTZq1)
type CTRing2 = CT PTIndex PTZq (Cyc T CTIndex CTZq2)
type SKRing = Cyc T CTIndex (LiftOf PTZq)

main :: IO ()
main = do
  plaintext <- getRandom
  sk :: SK SKRing <- genSK (1 :: Double)
  -- encrypt with a single modulus
  ciphertext :: CTRing1 <- encrypt sk plaintext

  let ct1 = 2*ciphertext
      pt1 = decrypt sk ct1
  print $ "Test1: " ++ (show $ 2*plaintext == pt1)

  kswq <- proxyT (keySwitchQuadCirc sk) (Proxy::Proxy (KSGad, CTZq2))
  let ct2 = kswq $ ciphertext*ciphertext
      pt2 = decrypt sk ct2
  -- note: this requires a *LARGE* CT modulus to succeed
  print $ "Test2: " ++ (show $ plaintext*plaintext == pt2)

  -- so we support using *several* small moduli:
  kswq' <- proxyT (keySwitchQuadCirc sk) (Proxy::Proxy (KSGad, CTZq3))
  ciphertext' :: CTRing2 <- encrypt sk plaintext
  let ct3 = kswq' $ ciphertext' * ciphertext'
      -- the CT modulus of ct3 is a ring product, which can't be lifted to a fixed size repr
      -- so use decryptUnrestricted instead
      pt3 = decryptUnrestricted sk ct3
      ct3' = rescaleLinearCT ct3 :: CTRing1
      -- after rescaling, ct3' has a single modulus, so we can use normal decrypt
      pt3' = decrypt sk ct3'
  print $ "Test3: " ++ (show $ (plaintext*plaintext == pt3) && (pt3' == pt3))

