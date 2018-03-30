{-|
Module      : Crypto.Lol.Cyclotomic.Tensor.CPP
Description : Wrapper for a C++ implementation of the 'Tensor' interface.
Copyright   : (c) Eric Crockett, 2011-2017
                  Chris Peikert, 2011-2017
License     : GPL-3
Maintainer  : ecrockett0@email.com
Stability   : experimental
Portability : POSIX

Wrapper for a C++ implementation of the 'Tensor' interface.
-}

{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs               #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RebindableSyntax           #-}
{-# LANGUAGE RoleAnnotations            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE CPP                        #-}

module Crypto.Lol.Cyclotomic.Tensor.CPP (CT) where

import Algebra.Additive     as Additive (C)
import Algebra.Module       as Module (C)
import Algebra.ZeroTestable as ZeroTestable (C)

import Control.Applicative    hiding ((*>))
import Control.Arrow          ((***))
import Control.DeepSeq
import Control.Monad.Except
import Control.Monad.Identity (Identity (..), runIdentity)
import Control.Monad.Random
import Control.Monad.Trans    as T (lift)

import Data.Coerce
import Data.Constraint              hiding ((***))
import Data.Int
import Data.Maybe
import Data.Traversable             as T
import Data.Vector.Generic          as V (fromList, toList, unzip)
import Data.Vector.Storable         as SV (Vector, convert, foldl',
                                           fromList, generate,
                                           length, map, replicate,
                                           replicateM, thaw, thaw, toList,
                                           unsafeFreeze,
                                           unsafeWith, zipWith, (!))
import Data.Vector.Storable.Mutable as SM hiding (replicate)

import Foreign.Marshal.Utils (with)
import Foreign.Ptr

import Crypto.Lol.CRTrans
import Crypto.Lol.Cyclotomic.Tensor
import Crypto.Lol.Cyclotomic.Tensor.CPP.Backend
import Crypto.Lol.Cyclotomic.Tensor.CPP.Extension
import Crypto.Lol.Cyclotomic.Tensor.CPP.Instances ()
import Crypto.Lol.GaussRandom
import Crypto.Lol.Prelude                             as LP hiding
                                                             (replicate,
                                                             unzip, zip)
import Crypto.Lol.Reflects
import Crypto.Lol.Tests
import Crypto.Lol.Types.FiniteField
import Crypto.Lol.Types.IFunctor
import Crypto.Lol.Types.IZipVector
import Crypto.Lol.Types.Proto
import Crypto.Lol.Types.Unsafe.ZqBasic

import Data.Foldable as F

import System.IO.Unsafe (unsafePerformIO)

-- | Newtype wrapper around a Vector.
newtype CT' (m :: Factored) r = CT' { unCT' :: Vector r }
                              deriving (Show, Eq, NFData)

-- the first argument, though phantom, affects representation
type role CT' representational nominal

-- GADT wrapper that distinguishes between Unbox and unrestricted
-- element types

-- | An implementation of 'Tensor' backed by C++ code.
data CT (m :: Factored) r where
  CT :: Storable r => CT' m r -> CT m r
  ZV :: IZipVector m r -> CT m r

deriving instance Show r => Show (CT m r)

instance Show (ArgType CT) where
  show _ = "CT"

instance Eq r => Eq (CT m r) where
  (ZV x) == (ZV y) = x == y
  (CT x) == (CT y) = x == y
  x@(CT _) == y = x == toCT y
  y == x@(CT _) = x == toCT y

instance (ForallFact2 Protoable IZipVector r, Fact m, Storable r) => Protoable (CT m r) where
  type ProtoType (CT m r) = ProtoType (IZipVector m r)

  toProto x@(CT _) = toProto $ toZV x \\ (entailFact2 :: Fact m :- Protoable (IZipVector m r))
  toProto (ZV x) = toProto x \\ (entailFact2 :: Fact m :- Protoable (IZipVector m r))

  fromProto x = toCT <$> ZV <$> fromProto x \\ (entailFact2 :: Fact m :- Protoable (IZipVector m r))

toCT :: (Storable r) => CT m r -> CT m r
toCT v@(CT _) = v
toCT (ZV v) = CT $ zvToCT' v

toZV :: (Fact m) => CT m r -> CT m r
toZV (CT (CT' v)) = ZV $ fromMaybe (error "toZV: internal error") $
                    iZipVector $ convert v
toZV v@(ZV _) = v

zvToCT' :: forall m r . (Storable r) => IZipVector m r -> CT' m r
zvToCT' v = coerce (convert $ unIZipVector v :: Vector r)

wrap :: (Storable s, Storable r) => (CT' l s -> CT' m r) -> (CT l s -> CT m r)
{-# INLINABLE wrap #-}
wrap f (CT v) = CT $ f v
wrap f (ZV v) = CT $ f $ zvToCT' v

wrapM :: (Storable s, Storable r, Monad mon) => (CT' l s -> mon (CT' m r))
         -> (CT l s -> mon (CT m r))
{-# INLINABLE wrapM #-}
wrapM f (CT v) = CT <$> f v
wrapM f (ZV v) = CT <$> f (zvToCT' v)

-- convert an CT' *twace* signature to Tagged one
type family Tw (r :: *) :: * where
  Tw (CT' m' r -> CT' m r) = Tagged '(m,m') (Vector r -> Vector r)
  Tw (Maybe (CT' m' r -> CT' m r)) = TaggedT '(m,m') Maybe (Vector r -> Vector r)

type family Em r where
  Em (CT' m r -> CT' m' r) = Tagged '(m,m') (Vector r -> Vector r)
  Em (Maybe (CT' m r -> CT' m' r)) = TaggedT '(m,m') Maybe (Vector r -> Vector r)


---------- NUMERIC PRELUDE INSTANCES ----------

-- CJP: Additive, Ring are not necessary when we use zipWithT
-- EAC: This has performance implications for the CT backend,
--      which used a (very fast) C function for (*) and (+)
instance (Additive r, Storable r, Fact m)
  => Additive.C (CT m r) where
  (CT (CT' a)) + (CT (CT' b)) = CT $ CT' $ SV.zipWith (+) a b
  a + b = toCT a + toCT b
  negate (CT (CT' a)) = CT $ CT' $ SV.map negate a -- EAC: This probably should be converted to C code
  negate a = negate $ toCT a

  zero = CT $ repl zero

{-
instance (Fact m, Ring r, Storable r, Dispatch r)
  => Ring.C (CT m r) where
  (CT a@(CT' _)) * (CT b@(CT' _)) = CT $ (untag $ cZipDispatch dmul) a b

  fromInteger = CT . repl . fromInteger
-}

instance (ZeroTestable r, Storable r) => ZeroTestable.C (CT m r) where
  --{-# INLINABLE isZero #-}
  isZero (CT (CT' a)) = SV.foldl' (\ b x -> b && isZero x) True a
  isZero (ZV v) = isZero v

instance (GFCtx fp d, Fact m, Additive (CT m fp))
    => Module.C (GF fp d) (CT m fp) where

  r *> v = case v of
    CT (CT' arr) -> CT $ CT' $ SV.fromList $ unCoeffs $ r *> Coeffs $ SV.toList arr
    ZV zv -> ZV $ fromJust $ iZipVector $ V.fromList $ unCoeffs $ r *> Coeffs $ V.toList $ unIZipVector zv

---------- Category-theoretic instances ----------

instance Fact m => Functor (CT m) where
  -- Functor instance is implied by Applicative laws
  fmap f x = pure f <*> x

instance Fact m => Applicative (CT m) where
  pure = ZV . pure

  (ZV f) <*> (ZV a) = ZV (f <*> a)
  f@(ZV _) <*> v@(CT _) = f <*> toZV v

instance Fact m => Foldable (CT m) where
  -- Foldable instance is implied by Traversable
  foldMap = foldMapDefault

instance Fact m => Traversable (CT m) where
  traverse f r@(CT _) = T.traverse f $ toZV r
  traverse f (ZV v) = ZV <$> T.traverse f v

instance TensorGaussian CT Double where
  tweakedGaussianDec v = CT <$> cDispatchGaussian v

instance (Tensor CT (ZqBasic q Int64), PrimeField (ZqBasic q Int64))
    => TensorCRTSet CT (ZqBasic q Int64) where
  crtSetDec = (CT <$>) <$> coerceBasis crtSetDec'

instance IFunctor CT where
  type IFElt CT a = Storable a

  fmapI f (CT (CT' sv)) = CT $ CT' $ SV.map f sv
  fmapI f (ZV v) = fmapI f $ CT $ zvToCT' v

  zipWithI f (CT (CT' sv1)) (CT (CT' sv2)) = CT $ CT' $ SV.zipWith f sv1 sv2
  zipWithI f (CT sv) (ZV v) = zipWithI f (CT sv) (CT $ zvToCT' v)
  zipWithI f (ZV v) (CT sv) = zipWithI f (CT $ zvToCT' v) (CT sv)
  zipWithI f (ZV v1) (ZV v2) = zipWithI f (CT $ zvToCT' v1) (CT $ zvToCT' v2)

-- TODO: make all of dispatched functions type-specific (kill the Dispatch' type class)
#define TENSOR_DEF(ring_ty, ...) \
    instance (__VA_ARGS__) => Tensor CT (ring_ty) where \
      scalarPow = CT . scalarPow' ;\
     \
      l = wrap $ basicDispatch dl ;\
      lInv = wrap $ basicDispatch dlinv ;\
     \
      mulGPow = wrap $ basicDispatch dmulgpow ;\
      mulGDec = wrap $ basicDispatch dmulgdec ;\
     \
      divGPow = wrapM $ dispatchGInv dginvpow ;\
      divGDec = wrapM $ dispatchGInv dginvdec ;\
     \
      gSqNormDec (CT v) = untag gSqNormDec' v ;\
      gSqNormDec (ZV v) = gSqNormDec (CT $ zvToCT' v) ;\
     \
      twacePowDec = wrap $ runIdentity $ coerceTw twacePowDec' ;\
      embedPow = wrap $ runIdentity $ coerceEm embedPow' ;\
      embedDec = wrap $ runIdentity $ coerceEm embedDec' ;\
     \
      coeffs = wrapM $ coerceCoeffs coeffs' ;\
     \
      powBasisPow = (CT <$>) <$> coerceBasis powBasisPow' ;\
     \
      {-# INLINABLE scalarPow #-} ;\
      {-# INLINABLE l #-} ;\
      {-# INLINABLE lInv #-} ;\
      {-# INLINABLE mulGPow #-} ;\
      {-# INLINABLE mulGDec #-} ;\
      {-# INLINABLE divGPow #-} ;\
      {-# INLINABLE divGDec #-} ;\
      {-# INLINABLE twacePowDec #-} ;\
      {-# INLINABLE embedPow #-} ;\
      {-# INLINABLE embedDec #-} ;\
      {-# INLINABLE gSqNormDec #-} ;\
      {-# INLINABLE coeffs #-} ;\
      {-# INLINABLE powBasisPow #-} ;\

#define TENSORCRT_DEF(ring_ty, ...) \
    instance (__VA_ARGS__) => TensorCRT CT (ring_ty) where \
      crtFuncs = (,,,,) <$> \
        return (CT . repl) <*> \
        (wrap . untag (cZipDispatch dmul) <$> gCRT) <*> \
        (wrap . untag (cZipDispatch dmul) <$> gInvCRT) <*> \
        (wrap <$> untagT ctCRT) <*> \
        (wrap <$> untagT ctCRTInv) ;\
     \
      crtExtFuncs = (,) <$> (wrap <$> coerceTw twaceCRT') <*> (wrap <$> coerceEm embedCRT') ;\
     \
      {-# INLINABLE crtFuncs #-} ;\
      {-# INLINE crtExtFuncs #-} ;\

TENSOR_DEF(Int64)
TENSOR_DEF(ZqBasic q Int64, Reflects q Int64)
TENSOR_DEF(Double)

TENSORCRT_DEF(Int64)
TENSORCRT_DEF(ZqBasic q Int64, Reflects q Int64)
TENSORCRT_DEF(Double)

-- Need this for the ForallFact2 Module entailment below
instance (Fact m, Ring r, Storable r) => Module.C r (CT m r) where
  (*>) r = wrap $ coerce $ SV.map (r*)

---------- Entailments for CT ----------

instance (Ring r, Storable r) => ForallFact2 (Module.C r) CT r where
  entailFact2 = Sub Dict

instance ForallFact1 Applicative CT where
  entailFact1 = Sub Dict

instance ForallFact1 Traversable CT where
  entailFact1 = Sub Dict

instance (ZeroTestable r, Storable r) => ForallFact2 ZeroTestable.C CT r where
  entailFact2 = Sub Dict

instance (Additive fp, Storable fp, GFCtx fp d) => ForallFact2 (Module.C (GF fp d)) CT fp where
  entailFact2 = Sub Dict

instance (ForallFact2 Protoable IZipVector r, Storable r) => ForallFact2 Protoable CT r where
  entailFact2 = Sub Dict

---------- Helper functions for coercion ----------

coerceTw :: (Functor mon) => TaggedT '(m, m') mon (Vector r -> Vector r) -> mon (CT' m' r -> CT' m r)
coerceTw = (coerce <$>) . untagT

coerceEm :: (Functor mon) => TaggedT '(m, m') mon (Vector r -> Vector r) -> mon (CT' m r -> CT' m' r)
coerceEm = (coerce <$>) . untagT

-- | Useful coersion for defining @coeffs@ in the @Tensor@
-- interface. Using 'coerce' alone is insufficient for type inference.
coerceCoeffs :: Tagged '(m,m') (Vector r -> [Vector r]) -> CT' m' r -> [CT' m r]
coerceCoeffs = coerce

-- | Useful coersion for defining @powBasisPow@ and @crtSetDec@ in the @Tensor@
-- interface. Using 'coerce' alone is insufficient for type inference.
coerceBasis :: Tagged '(m,m') [Vector r] -> Tagged m [CT' m' r]
coerceBasis = coerce

---------- Helper Functions for dispatch ----------

dispatchGInv :: forall m r . (Storable r, Fact m)
             => (Ptr r -> Int64 -> Ptr CPP -> Int16 -> IO Int16)
                 -> CT' m r -> Maybe (CT' m r)
dispatchGInv f =
  let factors = proxy (marshalFactors <$> ppsFact) (Proxy::Proxy m)
      totm = proxy (fromIntegral <$> totientFact) (Proxy::Proxy m)
      numFacts = fromIntegral $ SV.length factors
  in \(CT' x) -> unsafePerformIO $ do
    yout <- SV.thaw x
    ret <- SM.unsafeWith yout (\pout ->
             SV.unsafeWith factors (\pfac ->
               f pout totm pfac numFacts))
    if ret /= 0
    then Just . CT' <$> unsafeFreeze yout
    else return Nothing

withBasicArgs :: forall m r . (Fact m, Storable r)
  => (Ptr r -> Int64 -> Ptr CPP -> Int16 -> IO ())
     -> CT' m r -> IO (CT' m r)
withBasicArgs f =
  let factors = proxy (marshalFactors <$> ppsFact) (Proxy::Proxy m)
      totm = proxy (fromIntegral <$> totientFact) (Proxy::Proxy m)
      numFacts = fromIntegral $ SV.length factors
  in \(CT' x) -> do
    yout <- SV.thaw x
    SM.unsafeWith yout (\pout ->
      SV.unsafeWith factors (\pfac ->
        f pout totm pfac numFacts))
    CT' <$> unsafeFreeze yout

basicDispatch :: (Storable r, Fact m)
                 => (Ptr r -> Int64 -> Ptr CPP -> Int16 -> IO ())
                     -> CT' m r -> CT' m r
basicDispatch f = unsafePerformIO . withBasicArgs f

gSqNormDec' :: (Storable r, Fact m, Dispatch r)
               => Tagged m (CT' m r -> r)
gSqNormDec' = return $ (!0) . unCT' . unsafePerformIO . withBasicArgs dnorm

ctCRT :: (Storable r, CRTrans mon r, Dispatch r, Fact m)
         => TaggedT m mon (CT' m r -> CT' m r)
ctCRT = do
  ru' <- ru
  return $ \x -> unsafePerformIO $
    withPtrArray ru' (flip withBasicArgs x . dcrt)

-- CTensor CRT^(-1) functions take inverse rus
ctCRTInv :: (Storable r, CRTrans mon r, Dispatch r, Fact m)
         => TaggedT m mon (CT' m r -> CT' m r)
ctCRTInv = do
  mhatInv <- snd <$> crtInfo
  ruinv' <- ruInv
  return $ \x -> unsafePerformIO $
    withPtrArray ruinv' (\ruptr -> with mhatInv (flip withBasicArgs x . dcrtinv ruptr))

cZipDispatch :: (Storable r, Fact m)
  => (Ptr r -> Ptr r -> Int64 -> IO ())
     -> Tagged m (CT' m r -> CT' m r -> CT' m r)
cZipDispatch f = do -- in Tagged m
  totm <- fromIntegral <$> totientFact
  return $ coerce $ \a b -> unsafePerformIO $ do
    yout <- SV.thaw a
    SM.unsafeWith yout (\pout ->
      SV.unsafeWith b (\pin ->
        f pout pin totm))
    unsafeFreeze yout

cDispatchGaussian :: forall m r var rnd .
         (Storable r, Transcendental r, Dispatch r, Ord r,
          Fact m, ToRational var, Random r, MonadRandom rnd)
         => var -> rnd (CT' m r)
cDispatchGaussian var = flip proxyT (Proxy::Proxy m) $ do -- in TaggedT m rnd
  -- get rus for (Complex r)
  -- takes ru (not ruInv) to match RT
  ruinv' <- mapTaggedT (return . fromMaybe (error "complexGaussianRoots")) ru
  totm <- pureT totientFact
  mval <- pureT valueFact
  rad <- pureT radicalFact
  yin <- T.lift $ realGaussians (var * fromIntegral (mval `div` rad)) totm
  return $ unsafePerformIO $
    withPtrArray ruinv' (\ruptr -> withBasicArgs (dgaussdec ruptr) (CT' yin))

---------- Misc instances and arithmetic ----------

instance (Storable r, Random r, Fact m) => Random (CT' m r) where
  --{-# INLINABLE random #-}
  random = runRand $ replM (liftRand random)

  randomR = error "randomR nonsensical for CT'"

instance (Storable r, Random (CT' m r)) => Random (CT m r) where
  --{-# INLINABLE random #-}
  random = runRand $ CT <$> liftRand random

  randomR = error "randomR nonsensical for CT"

instance (NFData r) => NFData (CT m r) where
  rnf (CT v) = rnf v
  rnf (ZV v) = rnf v

repl :: forall m r . (Fact m, Storable r) => r -> CT' m r
repl = let n = proxy totientFact (Proxy::Proxy m)
       in coerce . SV.replicate n

replM :: forall m r mon . (Fact m, Storable r, Monad mon)
         => mon r -> mon (CT' m r)
replM = let n = proxy totientFact (Proxy::Proxy m)
        in fmap coerce . SV.replicateM n

scalarPow' :: forall m r . (Fact m, Additive r, Storable r) => r -> CT' m r
-- constant-term coefficient is first entry wrt powerful basis
scalarPow' =
  let n = proxy totientFact (Proxy::Proxy m)
  in \r -> CT' $ generate n (\i -> if i == 0 then r else zero)

ru, ruInv :: (CRTrans mon r, Fact m, Storable r)
   => TaggedT m mon [Vector r]
ru = do
  mval <- pureT valueFact
  wPow <- fst <$> crtInfo
  LP.map
    (\(p,e) -> do
        let pp = p^e
            pow = mval `div` pp
        generate pp (wPow . (*pow))) <$>
      pureT ppsFact

ruInv = do
  mval <- pureT valueFact
  wPow <- fst <$> crtInfo
  LP.map
    (\(p,e) -> do
        let pp = p^e
            pow = mval `div` pp
        generate pp (\i -> wPow $ -i*pow)) <$>
      pureT ppsFact

wrapVector :: forall mon m r . (Monad mon, Fact m, Ring r, Storable r)
  => TaggedT m mon (Kron r) -> mon (CT' m r)
wrapVector v = do
  vmat <- proxyT v (Proxy::Proxy m)
  let n = proxy totientFact (Proxy::Proxy m)
  return $ CT' $ generate n (flip (indexK vmat) 0)

gCRT, gInvCRT :: (Storable r, CRTrans mon r, Fact m)
                 => mon (CT' m r)
gCRT = wrapVector gCRTK
gInvCRT = wrapVector gInvCRTK
