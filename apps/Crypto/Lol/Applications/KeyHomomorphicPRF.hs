{-# LANGUAGE ConstraintKinds, DataKinds, ExplicitNamespaces, FlexibleContexts,
             GADTs, InstanceSigs, KindSignatures, NoImplicitPrelude, PolyKinds, ScopedTypeVariables,
             TemplateHaskell, TypeFamilies, TypeOperators, UndecidableInstances #-}

-- An implementation of the ring-LWE key-homomorphic PRF from [BP14].

-- TODO: Determine exactly which functions should export.
module Crypto.Lol.Applications.KeyHomomorphicPRF
( combineVectors
, decomposeEntries
, FullTree(..)
, MMatrix
, SafeBitString(..)
, uAugmentBS
, uAugmentVector
, uComputePRF
, uFlipBit
, UFullTree(..)
, uLeft
, uRight
, uRootValue
) where

import qualified Algebra.Ring as Ring

import Crypto.Lol.Gadget
import Crypto.Lol.LatticePrelude as L
import Crypto.Lol.PosBin

import MathObj.Matrix as M

type MMatrix a = M.T a

-- | Type-safe bitstring.
data SafeBitString (n :: Pos) where
  Bit :: Bool -> SafeBitString O
  Cons :: Bool -> SafeBitString n -> SafeBitString (S n)

-- | Type-safe full tree.
data FullTree (n :: Pos) l v where
  Leaf :: l -> v -> FullTree O l v
  Internal :: v -> FullTree nl l v
                -> FullTree nr l v
                -> FullTree (AddPos nl nr) l v

-- | Splits the SafeBitString into two separate SafeBitStrings.
-- | Uses the context in which it is called to determine appropriate lengths.
{-splitSBS :: (n ~ AddPos nl nr) => SafeBitString n -> (SafeBitString nl, SafeBitString nr)
splitSBS (Cons b (Bit b')) = (Bit b, Bit b')
splitSBS (Cons b rest) =
  let (l,r) = splitSBS rest
  in (Cons b l, r)-}

-- | Returns the vector attached to the FullTree.
rootValue :: FullTree n l v -> v
rootValue (Leaf b v) = v
rootValue (Internal v l r) = v

-- | Augments the leaves of the FullTree with Bool values.
augmentSBS :: FullTree n () () -> -- ^ Full tree T (topology)
                    SafeBitString n -> -- Bit string x
                    FullTree n Bool () -- ^ Full tree T (bit on each leaf)
augmentSBS (Leaf _ _) (Bit b) = Leaf b ()
{-augmentSBS (Internal _ left right) bits =
  let (leftBits, rightBits) = splitSBS bits
  in Internal () (augmentSBS left leftBits) (augmentSBS right rightBits)-}

-- | Augments the nodes of the FullTree with MMatrix values.
{-augmentVector :: (Ring (DecompOf a), Lift a (DecompOf a), Reduce (DecompOf a) a,
                 Decompose (BaseBGad 2) a, LiftOf a ~ DecompOf a) =>
                 MMatrix a -> -- ^ Base vector a0
                 MMatrix a -> -- ^ Base vector a1
                 FullTree n Bool () -> -- ^ Full tree T (bit on each leaf)
                 FullTree n Bool (MMatrix a) -- ^ Full tree T (calculated a_T(x))
augmentVector a0 a1 (Leaf bit _)
  | bit = Leaf bit a1
  | otherwise = Leaf bit a0
augmentVector a0 a1 (Internal _ l r) =
  let l' = augmentVector a0 a1 l
      r' = augmentVector a0 a1 r
      c = combineVectors (rootValue l') (rootValue r')
  in (Internal c l' r')

-- | Equation (2.10) in [BP14] using a type-safe full tree.
computePRF :: (Ring a, Ring b, Rescale a b) =>
              FullTree n l (MMatrix a) -> -- ^ Full tree T
              a -> -- ^ secret s
              MMatrix b
computePRF t s = fmap (rescale . (L.*s)) (rootValue t)

-- | Flip the boolean value at a chosen leaf.
flipBit :: (Ring a) =>
           MMatrix a -> -- ^ Base vector a0
           MMatrix a -> -- ^ Base vector a1
           Pos -> -- ^ # of bit to flip
           FullTree n Bool (MMatrix a) -> -- ^ Full Tree T
           FullTree n Bool (MMatrix a) -- ^ Full Tree T (after bit flip)
flipBit a0 a1 O (Leaf b v)
  | b = Leaf (not b) a0
  | otherwise = Leaf (not b) a1
-- pseudocode available for the other case in 5/13/16 log.-}

-- | Unsafe full tree.
data UFullTree l v where
  ULeaf :: l -> v -> UFullTree l v
  UInternal :: Int -> Int -> v ->
               UFullTree l v ->
               UFullTree l v ->
               UFullTree l v

-- | Returns the vertex type attached to the UFullTree.
uRootValue :: UFullTree l v -> v
uRootValue (ULeaf _ v) = v
uRootValue (UInternal _ _ v _ _) = v


-- | Used for debugging.
uLeft :: UFullTree l v -> UFullTree l v
uLeft (UInternal _ _ _ l _) = l

-- | Used for debugging.
uRight :: UFullTree l v -> UFullTree l v
uRight (UInternal _ _ _ _ r) = r

-- | Augments the leaves of the UFullTree with Bool values.
uAugmentBS :: UFullTree () () -> -- ^ Full tree T (topology)
              [Bool] -> -- Bitstring x of size |T| (# of leaves)
              UFullTree Bool () -- ^ Full tree T (bit on each leaf)
uAugmentBS (ULeaf _ _) [bit] = ULeaf bit ()
uAugmentBS (UInternal ls rs _ left right) bits =
  let (leftBits, rightBits) = splitAt ls bits
  in UInternal ls rs () (uAugmentBS left leftBits) (uAugmentBS right rightBits)

-- | Augments the nodes of the UFullTree with MMatrix values.
uAugmentVector :: (Ring (DecompOf a), Decompose gad a,
                 Reduce (DecompOf a) a) =>
                 Tagged gad (MMatrix a) -> -- ^ Base vector a0
                 Tagged gad (MMatrix a) -> -- ^ Base vector a1
                 UFullTree Bool () -> -- ^ Full tree T (bit on each leaf)
                 UFullTree Bool (Tagged gad (MMatrix a)) -- ^ Full tree T (calculated a_T(x))
uAugmentVector a0 a1 (ULeaf b _) =
  ULeaf b $ if b then a1 else a0
uAugmentVector a0 a1 (UInternal nl nr _ l r) =
  let l' = uAugmentVector a0 a1 l
      r' = uAugmentVector a0 a1 r
      c = combineVectors (uRootValue l') (uRootValue r')
  in (UInternal nl nr c l' r')

-- | Equation (2.10) in [BP14] using an unsafe full tree.
uComputePRF :: (Ring a, Ring b, Rescale a b) =>
              UFullTree l (Tagged gad (MMatrix a)) -> -- ^ Full tree T
              a -> -- ^ secret s
              MMatrix b
uComputePRF t s = fmap (rescale . (*s)) (untag $ uRootValue t)


-- | Flip the boolean value at a chosen leaf.
-- | Updates the affected matrices at each node.
uFlipBit :: (Ring (DecompOf a), Lift a (DecompOf a),
           Decompose gad a, LiftOf a ~ DecompOf a) =>
           Tagged gad (MMatrix a) -> -- ^ Base vector a0
           Tagged gad (MMatrix a) -> -- ^ Base vector a1
           Int -> -- ^ # of bit to flip
           UFullTree Bool (Tagged gad (MMatrix a)) -> -- ^ Full Tree T
           UFullTree Bool (Tagged gad (MMatrix a)) -- ^ Full Tree T (after bit flip)
uFlipBit a0 a1 _ (ULeaf b v) =
  ULeaf (not b) $ if b then a0 else a1
uFlipBit a0 a1 n (UInternal nl nr v l r)
  | (n > nl) =
    let r' = uFlipBit a0 a1 (n - nl) r
    in UInternal nl nr (combineVectors (uRootValue l) (uRootValue r')) l r'
  | otherwise =
    let l' = uFlipBit a0 a1 n l
    in UInternal nl nr (combineVectors (uRootValue l') (uRootValue r)) l' r

-- | Decomposes the entries of a 1xn MMatrix. Returns an nxn MMatrix.
decomposeEntries :: forall a gad.
                    (Decompose gad a) =>
                    Tagged gad (MMatrix a) ->
                    Tagged gad (MMatrix (DecompOf a))
decomposeEntries tm = do
  m <- tm
  let n = M.numColumns m
      taggedList = (fmap decompose $ concat $ M.rows m) :: [Tagged gad [DecompOf a]]
  return (M.fromColumns n n $ fmap (take n . untag) $ taggedList)

-- | Multiply two vectors as given in the
-- | "otherwise" case of Equation (2.9) in [BP14].
combineVectors :: forall a gad.
                  (Ring a, Decompose gad a,
                  Reduce (DecompOf a) a) =>
                  Tagged gad (MMatrix a) ->
                  Tagged gad (MMatrix a) ->
                  Tagged gad (MMatrix a)
combineVectors tl tr = do
  l <- tl
  let td = decomposeEntries tr
  return (l * (fmap reduce $ untag td))
