-- TODO: <https://git-scm.com/book/en/v2/Git-Branching-Basic-Branching-and-Merging>
{-# LANGUAGE CPP
           , DataKinds
           , PolyKinds
           , GADTs
           , Rank2Types
           , StandaloneDeriving
           , ScopedTypeVariables
           , TypeOperators
           , TypeFamilies
           #-}

{-# OPTIONS_GHC -Wall -fwarn-tabs #-}
----------------------------------------------------------------
--                                                    2015.07.15
-- |
-- Module      :  Language.Hakaru.Syntax.AST
-- Copyright   :  Copyright (c) 2015 the Hakaru team
-- License     :  BSD3
-- Maintainer  :  wren@community.haskell.org
-- Stability   :  experimental
-- Portability :  GHC-only
--
-- The generating functor for the raw syntax, along with various
-- helper types.
--
-- TODO: are we finally at the place where we can get rid of all
-- those annoying underscores?
--
-- TODO: what is the runtime cost of storing all these dictionary
-- singletons? For existential type variables, it should be the
-- same as using a type class constraint; but for non-existential
-- type variables it'll, what, double the size of the AST?
----------------------------------------------------------------
module Language.Hakaru.Syntax.AST
    (
    -- * Constant values
      Value(..),   sing_Value
    -- * Primitive operators
    , NaryOp(..),  sing_NaryOp
    , PrimOp(..),  sing_PrimOp
    , Measure(..), sing_Measure
    -- * User-defined datatypes
    -- ** Data constructors\/patterns
    , Datum(..)
    , DatumCode(..)
    , DatumStruct(..)
    , DatumFun(..)
    -- *** Some smart constructors for the \"built-in\" datatypes
    , dTrue, dFalse
    , dUnit
    , dPair
    , dLeft, dRight
    , dNil, dCons
    , dNothing, dJust
    -- ** Pattern matching
    , Pattern(..)
    , Branch(..), branchPattern, branchBody
    -- *** Some smart constructors for the \"built-in\" datatypes
    , pTrue, pFalse
    , pUnit
    , pPair
    , pLeft, pRight
    , pNil, pCons
    , pNothing, pJust
    -- * Syntactic forms
    , AST(..)
    ) where

import Data.Sequence           (Seq)
import qualified Data.Foldable as F
#if __GLASGOW_HASKELL__ < 710
import Data.Monoid             hiding (Sum)
#endif
import Control.Arrow           ((***))
import Data.Number.LogFloat    (LogFloat)

import Language.Hakaru.Syntax.Nat
import Language.Hakaru.Syntax.IClasses
import Language.Hakaru.Syntax.DataKind
import Language.Hakaru.Syntax.TypeEq
import Language.Hakaru.Syntax.HClasses
import Language.Hakaru.Syntax.Coercion

----------------------------------------------------------------
----------------------------------------------------------------
-- TODO: use 'Integer' instead of 'Int', and 'Natural' instead of 'Nat'.
-- | Constant values for primitive numeric types and user-defined
-- data-types.
data Value :: Hakaru -> * where
    VNat  :: {-# UNPACK #-} !Nat      -> Value 'HNat
    VInt  :: {-# UNPACK #-} !Int      -> Value 'HInt
    VProb :: {-# UNPACK #-} !LogFloat -> Value 'HProb
    VReal :: {-# UNPACK #-} !Double   -> Value 'HReal
    VDatum
        :: {-# UNPACK #-} !(Datum Value ('HData t (Code t)))
        -> Value ('HData t (Code t))

instance Eq1 Value where
    eq1 (VNat   v1) (VNat   v2) = v1 == v2
    eq1 (VInt   v1) (VInt   v2) = v1 == v2
    eq1 (VProb  v1) (VProb  v2) = v1 == v2
    eq1 (VReal  v1) (VReal  v2) = v1 == v2
    eq1 (VDatum v1) (VDatum v2) = v1 `eq1` v2
    eq1 _           _           = False -- impossible...

instance Eq (Value a) where
    (==) = eq1

-- TODO: instance Read (Value a)

instance Show1 Value where
    showsPrec1 p t =
        case t of
        VNat   v -> showParen_0 p "VNat"   v
        VInt   v -> showParen_0 p "VInt"   v
        VProb  v -> showParen_0 p "VProb"  v
        VReal  v -> showParen_0 p "VReal"  v
        VDatum v -> showParen_1 p "VDatum" v

instance Show (Value a) where
    showsPrec = showsPrec1
    show      = show1

-- N.B., we do case analysis so that we don't need the class constraint!
sing_Value :: Value a -> Sing a
sing_Value (VNat   _) = sing
sing_Value (VInt   _) = sing
sing_Value (VProb  _) = sing
sing_Value (VReal  _) = sing
sing_Value (VDatum (Datum d)) = error "TODO: sing_Value{VDatum}"
    {-
    -- @fmap1 sing_Value d@ gets us halfway there, but then what....
    -- This seems vaguely on the right track; but how can we get
    -- it to actually typecheck? Should we just have VDatum (or
    -- Datum) store the Sing when it's created?
    SData sing (goC d)
    where
    goC :: DatumCode xss Value a -> Sing xss
    goC (Inr d1)   = SPlus sing (goS d1)
    goC (Inl d1)   = SPlus (goC d1) sing

    goS :: DatumStruct xs Value a -> Sing xs
    goS (Et d1 d2) = SEt (goF d1) (goS d2)
    goS Done       = SDone

    goF :: DatumFun x Value a -> Sing x
    goF (Konst e1) = SKonst (sing_Value e1)
    goF (Ident e1) = SIdent -- @sing_Value e1@ is what the first argument to SData should be; assuming we actually make it to this branch...
    -}

----------------------------------------------------------------
-- TODO: helper functions for splitting NaryOp_ into components to group up like things.

-- | Primitive associative n-ary functions. By flattening the trees
-- for associative operators, we can more easily perform equivalence
-- checking and pattern matching (e.g., to convert @exp (a * log
-- b)@ into @b ** a@, regardless of whether @a@ is a product of
-- things or not). Notably, because of this encoding, we encode
-- things like subtraction and division by their unary operators
-- (negation and reciprocal).
--
-- We do not make any assumptions about whether these semigroups
-- are monoids, commutative, idempotent, or anything else. That has
-- to be handled by transformations, rather than by the AST itself.
data NaryOp :: Hakaru -> * where
    And  :: NaryOp HBool
    Or   :: NaryOp HBool
    Xor  :: NaryOp HBool
    -- N.B., even though 'Iff' is associative (in Boolean algebras),
    -- we should not support n-ary uses in our *surface* syntax.
    -- Because it's too easy for folks to confuse "a <=> b <=> c"
    -- with "(a <=> b) /\ (b <=> c)".
    Iff  :: NaryOp HBool -- == Not (Xor x y)

    -- These two don't necessarily have identity elements; thus,
    -- @NaryOp_ Min []@ and @NaryOp_ Max []@ may not be well-defined...
    -- TODO: check for those cases!
    Min  :: !(HOrd a) -> NaryOp a
    Max  :: !(HOrd a) -> NaryOp a

    Sum  :: !(HSemiring a) -> NaryOp a
    Prod :: !(HSemiring a) -> NaryOp a

    {-
    GCD  :: !(GCD_Domain a) -> NaryOp a
    LCM  :: !(GCD_Domain a) -> NaryOp a
    -}

deriving instance Eq   (NaryOp a)
-- TODO: instance Read (NaryOp a)
deriving instance Show (NaryOp a)


-- TODO: we don't need to store the HOrd\/HSemiring values here,
-- we can recover them by typeclass, just like we use 'sing' to get
-- 'sBool' for the other ones...
sing_NaryOp :: NaryOp a -> Sing a
sing_NaryOp And            = sing
sing_NaryOp Or             = sing
sing_NaryOp Xor            = sing
sing_NaryOp Iff            = sing
sing_NaryOp (Min  theOrd)  = sing_HOrd theOrd
sing_NaryOp (Max  theOrd)  = sing_HOrd theOrd
sing_NaryOp (Sum  theSemi) = sing_HSemiring theSemi
sing_NaryOp (Prod theSemi) = sing_HSemiring theSemi

----------------------------------------------------------------
-- | Simple primitive functions, and constants.
data PrimOp :: Hakaru -> * where

    -- -- -- Here we have /monomorphic/ operators
    -- -- The Boolean operators
    -- TODO: most of these we'll want to optimize away according
    -- to some circuit-minimization procedure. But we're not
    -- committing to any particular minimal complete set of primops
    -- just yet.
    -- N.B., general circuit minimization problem is Sigma_2^P-complete,
    -- which is outside of PTIME; so we'll just have to approximate
    -- it for now, or link into something like Espresso or an
    -- implementation of Quine–McCluskey
    -- cf., <https://hackage.haskell.org/package/qm-0.1.0.0/candidate>
    -- cf., <https://github.com/pfpacket/Quine-McCluskey>
    -- cf., <https://gist.github.com/dsvictor94/8db2b399a95e301c259a>
    Not  :: PrimOp (HBool ':-> HBool)
    -- And, Or, Xor, Iff
    Impl :: PrimOp (HBool ':-> HBool ':-> HBool) -- == Or (Not x) y
    Diff :: PrimOp (HBool ':-> HBool ':-> HBool) -- == Not (Impl x y)
    Nand :: PrimOp (HBool ':-> HBool ':-> HBool) -- aka Alternative Denial, Sheffer stroke
    Nor  :: PrimOp (HBool ':-> HBool ':-> HBool) -- aka Joint Denial, aka Quine dagger, aka Pierce arrow
    -- The remaining eight binops are completely uninteresting:
    --   flip Impl
    --   flip Diff
    --   const
    --   flip const
    --   (Not .) . const == const . Not
    --   (Not .) . flip const
    --   const (const True)
    --   const (const False)


    -- -- Trigonometry operators
    Pi    :: PrimOp 'HProb -- TODO: maybe make this HContinuous polymorphic?
    -- TODO: if we're going to bother naming the hyperbolic ones, why not also name /a?(csc|sec|cot)h?/ eh?
    -- TODO: capture more domain information in these types?
    Sin   :: PrimOp ('HReal ':-> 'HReal)
    Cos   :: PrimOp ('HReal ':-> 'HReal)
    Tan   :: PrimOp ('HReal ':-> 'HReal)
    Asin  :: PrimOp ('HReal ':-> 'HReal)
    Acos  :: PrimOp ('HReal ':-> 'HReal)
    Atan  :: PrimOp ('HReal ':-> 'HReal)
    Sinh  :: PrimOp ('HReal ':-> 'HReal)
    Cosh  :: PrimOp ('HReal ':-> 'HReal)
    Tanh  :: PrimOp ('HReal ':-> 'HReal)
    Asinh :: PrimOp ('HReal ':-> 'HReal)
    Acosh :: PrimOp ('HReal ':-> 'HReal)
    Atanh :: PrimOp ('HReal ':-> 'HReal)


    -- -- Other Real/Prob-valued operators
    -- N.B., we only give the safe/exact versions here. The old
    -- more lenient versions now require explicit coercions. Some
    -- of those coercions are safe, but others are not. This way
    -- we're explicit about where things can fail.
    -- N.B., we also have @NatPow{'HReal} :: 'HReal -> 'HNat -> 'HReal@,
    -- but non-integer real powers of negative reals are not real numbers!
    -- TODO: may need @SafeFrom_@ in order to branch on the input
    -- in order to provide the old unsafe behavior.
    RealPow   :: PrimOp ('HProb ':-> 'HReal ':-> 'HProb)
    -- ComplexPow :: PrimOp ('HProb ':-> 'HComplex ':-> 'HComplex)
    -- is uniquely well-defined. Though we may want to implement
    -- it via @r**z = ComplexExp (z * RealLog r)@
    -- Defining @HReal -> HComplex -> HComplex@ requires either
    -- multivalued functions, or a choice of complex logarithm and
    -- making it discontinuous.
    Exp       :: PrimOp ('HReal ':-> 'HProb)
    Log       :: PrimOp ('HProb ':-> 'HReal)
    -- TODO: Log1p, Expm1
    Infinity  :: PrimOp 'HProb -- TODO: maybe make this HContinuous polymorphic?
    NegativeInfinity :: PrimOp 'HReal -- TODO: maybe replace this by @negate (CoerceTo signed (PrimOp_ Infinity))@ ?
    -- TODO: add Factorial as the appropriate type restriction of GammaFunc?
    GammaFunc :: PrimOp ('HReal ':-> 'HProb)
    BetaFunc  :: PrimOp ('HProb ':-> 'HProb ':-> 'HProb)


    -- -- Continuous and discrete integration.
    -- TODO: make Integrate and Summate polymorphic, so that if the
    -- two inputs are HProb then we know the function must be over
    -- HProb\/HNat too. More generally, if the first input is HProb
    -- (since the second input is assumed to be greater thant he
    -- first); though that would be a bit ugly IMO.
    Integrate :: PrimOp
        (    'HReal
        ':-> 'HReal
        ':-> ('HReal ':-> 'HProb)
        ':-> 'HProb)
    Summate :: PrimOp
        (    'HReal -- TODO: should that really be 'HReal ?!
        ':-> 'HReal -- TODO: should that really be 'HReal ?!
        ':-> ('HInt ':-> 'HProb)
        ':-> 'HProb)


    -- -- -- Here we have the /polymorphic/ operators
    -- TODO: \"monomorphize\" these by passing explicit dictionary proxies

    -- -- Array stuff
    -- TODO: do these really belong here (as PrimOps), in AST, or in their own place (a la Datum)?
    -- HACK: is there any way we can avoid storing the Sing values here, while still implementing 'sing_PrimOp'? Should we have a Hakaru class for the types which can be stored in arrays? might not be a crazy idea...
    Index  :: !(Sing a) -> PrimOp ('HArray a ':-> 'HNat ':-> a)
    Size   :: !(Sing a) -> PrimOp ('HArray a ':-> 'HNat)
    -- The first argument should be a monoid, but we don't enforce
    -- that; it's the user's responsibility.
    Reduce
        :: !(Sing a)
        -> PrimOp ((a ':-> a ':-> a) ':-> a ':-> 'HArray a ':-> a)


    -- -- HEq and HOrd operators
    -- TODO: equality doesn't make constructive sense on the reals...
    -- would it be better to constructivize our notion of total ordering?
    Equal :: !(HEq  a) -> PrimOp (a ':-> a ':-> HBool)
    Less  :: !(HOrd a) -> PrimOp (a ':-> a ':-> HBool)


    -- -- HSemiring operators (the non-n-ary ones)
    NatPow :: !(HSemiring a) -> PrimOp (a ':-> 'HNat ':-> a)
    -- TODO: would it help to have a specialized version for when
    -- we happen to know that the 'HNat is a Value? Same goes for
    -- the other powers\/roots
    --
    -- TODO: add a specialized version which returns NonNegative
    -- when the power is even? N.B., be sure not to actually constrain
    -- it to HRing (necessary for calling it \"NonNegative\")


    -- -- HRing operators
    -- TODO: break these apart into a hierarchy of classes. N.B,
    -- there are two different interpretations of "abs" and "signum".
    -- On the one hand we can think of rings as being generated
    -- from semirings closed under subtraction/negation. From this
    -- perspective we have abs as a projection into the underlying
    -- semiring, and signum as a projection giving us the residual
    -- sign lost by the abs projection. On the other hand, we have
    -- the view of "abs" as a norm (i.e., distance to the "origin
    -- point"), which is the more common perspective for complex
    -- numbers and vector spaces; and relatedly, we have "signum"
    -- as returning the value on the unit (hyper)sphere, of the
    -- normalized unit vector. In another class, if we have a notion
    -- of an "origin axis" then we can have a function Arg which
    -- returns the angle to that axis, and therefore define signum
    -- in terms of Arg.
    -- Ring: Semiring + negate, abs, signum
    -- NormedLinearSpace: LinearSpace + originPoint, norm, Arg
    -- ??: NormedLinearSpace + originAxis, angle
    Negate :: !(HRing a) -> PrimOp (a ':-> a)
    Abs    :: !(HRing a) -> PrimOp (a ':-> NonNegative a)
    -- cf., <https://mail.haskell.org/pipermail/libraries/2013-April/019694.html>
    -- cf., <https://en.wikipedia.org/wiki/Sign_function#Complex_signum>
    -- Should we have Maple5's \"csgn\" as well as the usual \"sgn\"?
    -- Also note that the \"generalized signum\" anticommutes with Dirac delta!
    Signum :: !(HRing a) -> PrimOp (a ':-> a)
    -- Law: x = coerceTo_ signed (abs_ x) * signum x
    -- More strictly/exactly, the result of Signum should be either
    -- zero or an @a@-unit value. For Int and Real, the units are
    -- +1 and -1. For Complex, the units are any point on the unit
    -- circle. For vectors, the units are any unit vector. Thus,
    -- more generally:
    -- Law : x = coerceTo_ signed (abs_ x) `scaleBy` signum x
    -- TODO: would it be worth defining the associated type of unit values for @a@? Probably...
    -- TODO: are there any salient types which support abs\/norm but
    -- do not have all units and thus do not support signum\/normalize?


    -- -- HFractional operators
    Recip :: !(HFractional a) -> PrimOp (a ':-> a)
    -- generates macro: IntPow


    -- -- HRadical operators
    NatRoot :: !(HRadical a) -> PrimOp (a ':-> 'HNat ':-> a)
    -- generates macros: Sqrt, NonNegativeRationalPow, and RationalPow


    -- -- HContinuous operators
    -- TODO: what goes here, if anything? cf., <https://en.wikipedia.org/wiki/Closed-form_expression#Comparison_of_different_classes_of_expressions>
    Erf :: !(HContinuous a) -> PrimOp (a ':-> a)
    -- TODO: make Pi and Infinity HContinuous-polymorphic so that we can avoid the explicit coercion? Probably more mess than benefit.


    -- -- Internalized program transformations
    -- We generally want to evaluate these away at compile-time,
    -- but sometimes we may be stuck with a few unresolved things
    -- for open terms.
    --
    -- TODO: implement a \"change of variables\" program transformation
    -- to map, say, @Lam_ x. blah (Expect x)@ into @Lam x'. blah x'@.
    -- Or, perhaps rather, transform it into @Lam_ x. App_ (Lam_ x'. blah x') (Expect x)@.
    Expect
        :: !(Sing a)
        -> PrimOp ('HMeasure a ':-> (a ':-> 'HProb) ':-> 'HProb)

deriving instance Eq   (PrimOp a)
-- TODO: instance Read (PrimOp a)
deriving instance Show (PrimOp a)


-- TODO: we don't need to store the dictionary values here, we can
-- recover them by typeclass, just like we use 'sing' for the other
-- ones...
sing_PrimOp :: PrimOp a -> Sing a
sing_PrimOp Not         = sing
sing_PrimOp Impl        = sing
sing_PrimOp Diff        = sing
sing_PrimOp Nand        = sing
sing_PrimOp Nor         = sing
sing_PrimOp Pi          = sing
sing_PrimOp Sin         = sing
sing_PrimOp Cos         = sing
sing_PrimOp Tan         = sing
sing_PrimOp Asin        = sing
sing_PrimOp Acos        = sing
sing_PrimOp Atan        = sing
sing_PrimOp Sinh        = sing
sing_PrimOp Cosh        = sing
sing_PrimOp Tanh        = sing
sing_PrimOp Asinh       = sing
sing_PrimOp Acosh       = sing
sing_PrimOp Atanh       = sing
sing_PrimOp RealPow     = sing
sing_PrimOp Exp         = sing
sing_PrimOp Log         = sing
sing_PrimOp Infinity    = sing
sing_PrimOp NegativeInfinity = sing
sing_PrimOp GammaFunc   = sing
sing_PrimOp BetaFunc    = sing
sing_PrimOp Integrate   = sing
sing_PrimOp Summate     = sing
-- Mere case analysis isn't enough for the rest of these, because
-- of the class constraints. We fix that by various helper functions
-- on explicit dictionary passing.
--
-- TODO: is there any way to automate building these from their
-- respective @a@ proofs?
sing_PrimOp (Index  a) = SArray a `SFun` SNat `SFun` a
sing_PrimOp (Size   a) = SArray a `SFun` SNat
sing_PrimOp (Reduce a) =
    (a `SFun` a `SFun` a) `SFun` a `SFun` SArray a `SFun` a
sing_PrimOp (Equal theEq) =
    let a = sing_HEq theEq
    in  a `SFun` a `SFun` sBool
sing_PrimOp (Less theOrd) =
    let a = sing_HOrd theOrd
    in  a `SFun` a `SFun` sBool
sing_PrimOp (NatPow theSemi) =
    let a = sing_HSemiring theSemi
    in  a `SFun` SNat `SFun` a
sing_PrimOp (Negate theRing) =
    let a = sing_HRing theRing
    in  a `SFun` a
sing_PrimOp (Abs theRing) =
    let a = sing_HRing theRing
        b = sing_NonNegative theRing
    in  a `SFun` b
sing_PrimOp (Signum theRing) =
    let a = sing_HRing theRing
    in  a `SFun` a
sing_PrimOp (Recip theFrac) =
    let a = sing_HFractional theFrac
    in  a `SFun` a
sing_PrimOp (NatRoot theRad) =
    let a = sing_HRadical theRad
    in  a `SFun` SNat `SFun` a
sing_PrimOp (Erf theCont) =
    let a = sing_HContinuous theCont
    in  a `SFun` a
sing_PrimOp (Expect a) =
    SMeasure a `SFun` (a `SFun` SProb) `SFun` SProb

----------------------------------------------------------------
-- TODO: move the rest of the old Mochastic class into here?
-- | Primitive distributions\/measures.
data Measure :: Hakaru -> * where
    -- TODO: should we put Dirac back into the main AST?
    -- HACK: is there any way we can avoid storing the Sing value here, while still implementing 'sing_Measure'? Should we have a Hakaru class for the types which can be measurable? might not be a crazy idea...
    Dirac       :: !(Sing a) -> Measure (a ':-> 'HMeasure a)

    Lebesgue    :: Measure ('HMeasure 'HReal)
    Counting    :: Measure ('HMeasure 'HInt)
    Categorical :: Measure ('HArray 'HProb ':-> 'HMeasure 'HNat)
    -- TODO: make Uniform polymorphic, so that if the two inputs are HProb then we know the measure must be over HProb too. More generally, if the first input is HProb (since the second input is assumed to be greater thant he first); though that would be a bit ugly IMO.
    Uniform     :: Measure ('HReal ':-> 'HReal ':-> 'HMeasure 'HReal)
    Normal      :: Measure ('HReal ':-> 'HProb ':-> 'HMeasure 'HReal)
    Poisson     :: Measure ('HProb ':-> 'HMeasure 'HNat)
    Gamma       :: Measure ('HProb ':-> 'HProb ':-> 'HMeasure 'HProb)
    Beta        :: Measure ('HProb ':-> 'HProb ':-> 'HMeasure 'HProb)
    -- binomial, mix, geometric, multinomial,... should also be HNat

    -- HACK: is there any way we can avoid storing the Sing values here, while still implementing 'sing_Measure'? Should we have a Hakaru class for the types which can be measurable? might not be a crazy idea...
    DirichletProcess
        :: !(Sing a)
        -> Measure ('HProb ':-> 'HMeasure a ':-> 'HMeasure ('HMeasure a))
    -- TODO: unify Plate and Chain as 'sequence' a~la traversable?
    Plate
        :: !(Sing a)
        -> Measure ('HArray ('HMeasure a) ':-> 'HMeasure ('HArray a))
    Chain
        :: !(Sing s)
        -> !(Sing a)
        -> Measure
            ('HArray (s ':-> 'HMeasure (HPair a s)) ':->
            s ':-> 'HMeasure (HPair ('HArray a) s))


deriving instance Eq   (Measure a)
-- TODO: instance Read (Measure a)
deriving instance Show (Measure a)


sing_Measure :: Measure a -> Sing a
sing_Measure (Dirac a)   = a `SFun` SMeasure a
sing_Measure Lebesgue    = sing
sing_Measure Counting    = sing
sing_Measure Categorical = sing
sing_Measure Uniform     = sing
sing_Measure Normal      = sing
sing_Measure Poisson     = sing
sing_Measure Gamma       = sing
sing_Measure Beta        = sing
sing_Measure (DirichletProcess a) =
    SProb `SFun` SMeasure a `SFun` SMeasure (SMeasure a)
sing_Measure (Plate a) =
    (SArray $ SMeasure a) `SFun` SMeasure (SArray a)
sing_Measure (Chain s a) =
    SArray (s `SFun` SMeasure (sPair a s))
    `SFun` s `SFun` SMeasure (sPair (SArray a) s)


----------------------------------------------------------------
----------------------------------------------------------------
-- TODO: add the constructor name as another component of this record, to improve error messages etc.
--
-- TODO: add @Sing ('HData t (Code t))@ to the Datum constructor?
--
-- | A fully saturated data constructor\/pattern, with leaves in
-- @ast@. We define this type as separate from 'DatumCode' for
-- two reasons. First is to capture the fact that the datum is
-- \"complete\", i.e., is a well-formed constructor\/pattern. The
-- second is to have a type which is indexed by its 'Hakaru' type,
-- whereas 'DatumCode' has non-Hakaru types.
data Datum :: (Hakaru -> *) -> Hakaru -> * where
    Datum
        :: !(DatumCode (Code t) abt ('HData t (Code t)))
        -> Datum abt ('HData t (Code t))

instance Eq1 abt => Eq1 (Datum abt) where
    eq1 (Datum d1) (Datum d2) = eq1 d1 d2

instance Eq1 abt => Eq (Datum abt a) where
    (==) = eq1

-- TODO: instance Read (Datum abt a)

instance Show1 abt => Show1 (Datum abt) where
    showsPrec1 p (Datum d) = showParen_1 p "Datum" d

instance Show1 abt => Show (Datum abt a) where
    showsPrec = showsPrec1
    show      = show1

instance Functor11 Datum where
    fmap11 f (Datum d) = Datum (fmap11 f d)

instance Foldable11 Datum where
    foldMap11 f (Datum d) = foldMap11 f d

----------------------------------------------------------------
infixr 7 `Et`, `PEt`

-- | The intermediate components of a data constructor. The intuition
-- behind the two indices is that the @[[HakaruFun]]@ is a functor
-- applied to the Hakaru type. Initially the @[[HakaruFun]]@ functor
-- will be the 'Code' associated with the Hakaru type; hence it's
-- the one-step unrolling of the fixed point for our recursive
-- datatypes. But as we go along, we'll be doing induction on the
-- @[[HakaruFun]]@ functor.
data DatumCode :: [[HakaruFun]] -> (Hakaru -> *) -> Hakaru -> * where
    -- | Skip rightwards along the sum.
    Inr :: !(DatumCode  xss abt a) -> DatumCode (xs ': xss) abt a
    -- | Inject into the sum.
    Inl :: !(DatumStruct xs abt a) -> DatumCode (xs ': xss) abt a


-- N.B., these \"Foo1\" instances rely on polymorphic recursion,
-- since the @code@ changes at each constructor. However, we don't
-- actually need to abstract over @code@ in order to define these
-- functions, because (1) we never existentially close over any
-- codes, and (2) the code is always getting smaller; so we have
-- a good enough inductive hypothesis from polymorphism alone.

instance Eq1 abt => Eq1 (DatumCode xss abt) where
    eq1 (Inr c) (Inr d) = eq1 c d
    eq1 (Inl c) (Inl d) = eq1 c d
    eq1 _       _       = False

-- TODO: instance Read (DatumCode xss abt a)

instance Show1 abt => Show1 (DatumCode xss abt) where
    showsPrec1 p (Inr d) = showParen_1 p "Inr" d
    showsPrec1 p (Inl d) = showParen_1 p "Inl" d

instance Show1 abt => Show (DatumCode xss abt a) where
    showsPrec = showsPrec1

instance Functor11 (DatumCode xss) where
    fmap11 f (Inr d) = Inr (fmap11 f d)
    fmap11 f (Inl d) = Inl (fmap11 f d)

instance Foldable11 (DatumCode xss) where
    foldMap11 f (Inr d) = foldMap11 f d
    foldMap11 f (Inl d) = foldMap11 f d


data DatumStruct :: [HakaruFun] -> (Hakaru -> *) -> Hakaru -> * where
    -- | Combine components of the product. (\"et\" means \"and\" in Latin)
    Et  :: !(DatumFun    x         abt a)
        -> !(DatumStruct xs        abt a)
        ->   DatumStruct (x ': xs) abt a

    -- | Close off the product.
    Done :: DatumStruct '[] abt a

instance Eq1 abt => Eq1 (DatumStruct xs abt) where
    eq1 (Et c1 c2) (Et d1 d2) = eq1 c1 d1 && eq1 c2 d2
    eq1 Done       Done       = True
    eq1 _          _          = False

-- TODO: instance Read (DatumStruct xs abt a)

instance Show1 abt => Show1 (DatumStruct xs abt) where
    showsPrec1 p (Et d1 d2) = showParen_11 p "Et" d1 d2
    showsPrec1 _ Done       = showString     "Done"

instance Show1 abt => Show (DatumStruct xs abt a) where
    showsPrec = showsPrec1

instance Functor11 (DatumStruct xs) where
    fmap11 f (Et d1 d2) = Et (fmap11 f d1) (fmap11 f d2)
    fmap11 _ Done       = Done

instance Foldable11 (DatumStruct xs) where
    foldMap11 f (Et d1 d2) = foldMap11 f d1 `mappend` foldMap11 f d2
    foldMap11 _ Done       = mempty


-- TODO: do we like those constructor names? Should we change them?
data DatumFun :: HakaruFun -> (Hakaru -> *) -> Hakaru -> * where
    -- | Hit a leaf which isn't a recursive component of the datatype.
    Konst :: abt b -> DatumFun ('K b) abt a
    -- | Hit a leaf which is a recursive component of the datatype.
    Ident :: abt a -> DatumFun 'I     abt a

instance Eq1 abt => Eq1 (DatumFun x abt) where
    eq1 (Konst e) (Konst f) = eq1 e f
    eq1 (Ident e) (Ident f) = eq1 e f
    eq1 _         _         = False

-- TODO: instance Read (DatumFun x abt a)

instance Show1 abt => Show1 (DatumFun x abt) where
    showsPrec1 p (Konst e) = showParen_1 p "Konst" e
    showsPrec1 p (Ident e) = showParen_1 p "Ident" e

instance Show1 abt => Show (DatumFun x abt a) where
    showsPrec = showsPrec1

instance Functor11 (DatumFun x) where
    fmap11 f (Konst e) = Konst (f e)
    fmap11 f (Ident e) = Ident (f e)

instance Foldable11 (DatumFun x) where
    foldMap11 f (Konst e) = f e
    foldMap11 f (Ident e) = f e


-- In GHC 7.8 we can make the monomorphic smart constructors into
-- pattern synonyms, but 7.8 can't handle anything polymorphic (but
-- GHC 7.10 can). For libraries (e.g., "Language.Hakaru.Syntax.Prelude")
-- we can use functions to construct our Case_ statements, so library
-- designers don't need pattern synonyms. Whereas, for the internal
-- aspects of the compiler, we need to handle all possible Datum
-- values, so the pattern synonyms wouldn't even be helpful.

dTrue, dFalse :: Datum abt HBool
dTrue      = Datum . Inl $ Done
dFalse     = Datum . Inr . Inl $ Done

dUnit      :: Datum abt HUnit
dUnit      = Datum . Inl $ Done

dPair      :: abt a -> abt b -> Datum abt (HPair a b)
dPair a b  = Datum . Inl $ Konst a `Et` Konst b `Et` Done

dLeft      :: abt a -> Datum abt (HEither a b)
dLeft      = Datum . Inl . (`Et` Done) . Konst

dRight     :: abt b -> Datum abt (HEither a b)
dRight     = Datum . Inr . Inl . (`Et` Done) . Konst

dNil       :: Datum abt (HList a)
dNil       = Datum . Inl $ Done

dCons      :: abt a -> abt (HList a) -> Datum abt (HList a)
dCons x xs = Datum . Inr . Inl $ Konst x `Et` Ident xs `Et` Done

dNothing   :: Datum abt (HMaybe a)
dNothing   = Datum . Inl $ Done

dJust      :: abt a -> Datum abt (HMaybe a)
dJust      = Datum . Inr . Inl . (`Et` Done) . Konst


----------------------------------------------------------------
-- TODO: negative patterns? (to facilitate reordering of case branches)
-- TODO: disjunctive patterns, a~la ML?
-- TODO: equality patterns for Nat\/Int? (what about Prob\/Real??)
-- TODO: exhaustiveness, non-overlap, dead-branch checking
--
-- TODO: index by @[Hakaru]@ to keep track of the number\/types of the 'PVar's. It seems like this will mean defining our own specific type for @Datum Pattern@ in order to collect up the variables in each branch of products\/structs.
--
-- We index patterns by the type they scrutinize. This requires the
-- parser to be smart enough to build these patterns up, but then
-- it guarantees that we can't have 'Case_' of patterns which can't
-- possibly match according to our type system. If we wanted to go
-- really crazy, we could also index patterns by the type of what
-- variables they bind, like we'll do for ASTPattern... But that's
-- prolly overkill since we can just run the type checker over our
-- AST.
{-
data Pattern :: Hakaru -> * where
    -- | The \"don't care\" wildcard pattern.
    PWild :: Pattern a

    -- | A pattern variable.
    PVar  :: Pattern a

    -- | A data type constructor pattern.
    PDatum
        :: {-# UNPACK #-} !(Datum Pattern ('HData t (Code t)))
        -> Pattern ('HData t (Code t))


instance Eq1 Pattern where
    eq1 PWild       PWild       = True
    eq1 PVar        PVar        = True
    eq1 (PDatum d1) (PDatum d2) = eq1 d1 d2
    eq1 _           _           = False

instance Eq (Pattern a) where
    (==) = eq1

-- TODO: instance Read (Pattern a)

instance Show1 Pattern where
    showsPrec1 _ PWild      = showString    "PWild"
    showsPrec1 _ PVar       = showString    "PVar"
    showsPrec1 p (PDatum d) = showParen_1 p "PDatum" d

instance Show (Pattern a) where
    showsPrec = showsPrec1
    show      = show1
-}

data Pattern :: [Hakaru] -> Hakaru -> * where
    PWild :: Pattern '[]    a
    PVar  :: Pattern '[ a ] a
    PDatum
        :: !(PDatumCode (Code t) vars ('HData t (Code t)))
        -> Pattern vars ('HData t (Code t))

instance Eq1 (Pattern vars) where
    eq1 PWild       PWild       = True
    eq1 PVar        PVar        = True
    eq1 (PDatum d1) (PDatum d2) = eq1 d1 d2
    eq1 _           _           = False

instance Eq (Pattern vars a) where
    (==) = eq1

-- TODO: instance Read (Pattern vars a)

instance Show1 (Pattern vars) where
    showsPrec1 _ PWild      = showString    "PWild"
    showsPrec1 _ PVar       = showString    "PVar"
    showsPrec1 p (PDatum d) = showParen_1 p "PDatum" d

instance Show (Pattern vars a) where
    showsPrec = showsPrec1
    show      = show1


data PDatumCode :: [[HakaruFun]] -> [Hakaru] -> Hakaru -> * where
    PInr :: !(PDatumCode  xss vars a) -> PDatumCode (xs ': xss) vars a
    PInl :: !(PDatumStruct xs vars a) -> PDatumCode (xs ': xss) vars a

instance Eq1 (PDatumCode xss vars) where
    eq1 (PInr c) (PInr d) = eq1 c d
    eq1 (PInl c) (PInl d) = eq1 c d
    eq1 _        _        = False

-- TODO: instance Read (PDatumCode xss vars a)

instance Show1 (PDatumCode xss vars) where
    showsPrec1 p (PInr d) = showParen_1 p "PInr" d
    showsPrec1 p (PInl d) = showParen_1 p "PInl" d

instance Show (PDatumCode xss vars a) where
    showsPrec = showsPrec1


-- BUG: how do we actually use the term-level @(++)@ at the type level? Or do we have to redefine it ourselves (as below)? If we define it ourselves, how do we make it a closed family? or ensure invertability\/inference in other ways? What are the usability problems of not having the full relational modes specified?
type family (xs :: [k]) ++ (ys :: [k]) :: [k]
type instance '[]       ++ ys = ys 
type instance (x ': xs) ++ ys = x ': (xs ++ ys) 

data PDatumStruct :: [HakaruFun] -> [Hakaru] -> Hakaru -> * where
    PEt :: !(PDatumFun    x         vars1 a)
        -> !(PDatumStruct xs        vars2 a)
        ->   PDatumStruct (x ': xs) (vars1 ++ vars2) a

    PDone :: PDatumStruct '[] '[] a

instance Eq1 (PDatumStruct xs vars) where
    eq1 (PEt c1 c2) (PEt d1 d2) =
        error "TODO: Eq1{PEt}: make sure existentials match up"
        -- > eq1 c1 d1 && eq1 c2 d2
        -- TODO: we could do it with some instance of @jmEq@; which is just further begging for making @jmEq@ into a kind-class (i.e., a typeclass indexed by a kind instead of by a type). /Could/ do it without that kind-class, but will be namespace ugliness
        -- TODO: maybe we could just push @jmEq@ into the 'Eq1' class like the other abt library on Haskage does?
    eq1 PDone       PDone       = True
    eq1 _           _           = False

-- TODO: instance Read (PDatumStruct xs vars a)

instance Show1 (PDatumStruct xs vars) where
    showsPrec1 p (PEt d1 d2) = showParen_11 p "PEt" d1 d2
    showsPrec1 _ PDone       = showString     "PDone"

instance Show (PDatumStruct xs vars a) where
    showsPrec = showsPrec1


data PDatumFun :: HakaruFun -> [Hakaru] -> Hakaru -> * where
    PKonst :: Pattern vars b -> PDatumFun ('K b) vars a
    PIdent :: Pattern vars a -> PDatumFun 'I     vars a

instance Eq1 (PDatumFun x vars) where
    eq1 (PKonst e) (PKonst f) = eq1 e f
    eq1 (PIdent e) (PIdent f) = eq1 e f
    eq1 _          _          = False

-- TODO: instance Read (PDatumFun x vars a)

instance Show1 (PDatumFun x vars) where
    showsPrec1 p (PKonst e) = showParen_1 p "PKonst" e
    showsPrec1 p (PIdent e) = showParen_1 p "PIdent" e

instance Show (PDatumFun x vars a) where
    showsPrec = showsPrec1


pTrue, pFalse :: Pattern '[] HBool
pTrue  = PDatum . PInl $ PDone
pFalse = PDatum . PInr . PInl $ PDone

pUnit  :: Pattern '[] HUnit
pUnit  = PDatum . PInl $ PDone

-- BUG: Couldn't match type ‘vars1 ++ (vars2 ++ '[])’ with ‘vars1 ++ vars2’
pPair
    :: Pattern vars1 a
    -> Pattern vars2 b
    -> Pattern (vars1 ++ vars2) (HPair a b)
pPair a b =
    error "TODO: make pPair typecheck"
    -- PDatum . PInl $ PKonst a `PEt` PKonst b `PEt` PDone

-- BUG: Couldn't match type ‘vars’ with ‘vars ++ '[]’
pLeft  :: Pattern vars a -> Pattern vars (HEither a b)
pLeft  = 
    error "TODO: make pLeft typecheck"
    -- PDatum . PInl . (`PEt` PDone) . PKonst

pRight :: Pattern vars b -> Pattern vars (HEither a b)
pRight = 
    error "TODO: make pRight typecheck"
    -- PDatum . PInr . PInl . (`PEt` PDone) . PKonst

pNil   :: Pattern '[] (HList a)
pNil   = PDatum . PInl $ PDone

pCons :: Pattern vars1 a
    -> Pattern vars2 (HList a)
    -> Pattern (vars1 ++ vars2) (HList a)
pCons x xs = 
    error "TODO: make pCons typecheck"
    -- PDatum . PInr . PInl $ PKonst x `PEt` PIdent xs `PEt` PDone

pNothing   :: Pattern '[] (HMaybe a)
pNothing   = PDatum . PInl $ PDone

pJust      :: Pattern vars a -> Pattern vars (HMaybe a)
pJust      = 
    error "TODO: make pJust typecheck"
    -- PDatum . PInr . PInl . (`PEt` PDone) . PKonst

----------------------------------------------------------------
-- TODO: a pretty infix syntax, like (:=>) or something
-- TODO: this type is helpful for capturing the existential, if we
-- ever end up keeping track of local binding environments; but
-- other than that, it should be replaced\/augmented with a type
-- for pattern automata, so we can optimize case analysis.
data Branch :: Hakaru -> ([Hakaru] -> Hakaru -> *) -> Hakaru -> * where
    Branch
        :: !(Pattern xs a)
        -> abt xs b
        -> Branch a abt b

branchPattern :: Branch a abt b -> (forall xs. Pattern xs a -> r) -> r
branchPattern (Branch p _) k = k p

branchBody :: Branch a abt b -> (forall xs. abt xs b -> r) -> r
branchBody (Branch _ e) k = k e

instance Eq2 abt => Eq1 (Branch a abt) where
    eq1 (Branch p1 e1) (Branch p2 e2) =
        error "TODO: Eq1{Branch}: make sure existentials match up"
        -- p1 `eq1` p2 && e1 `eq2` e2

instance Eq2 abt => Eq (Branch a abt b) where
    (==) = eq1

-- TODO: instance Read (Branch abt a b)

instance Show2 abt => Show1 (Branch a abt) where
    showsPrec1 p (Branch pat e) = showParen_02 p "Branch" pat e

instance Show2 abt => Show (Branch a abt b) where
    showsPrec = showsPrec1
    show      = show1

instance Functor21 (Branch a) where
    fmap21 f (Branch p e) = Branch p (f e)

instance Foldable21 (Branch a) where
    foldMap21 f (Branch _ e) = f e


----------------------------------------------------------------
-- TODO: define a well-formedness check for the ABT structure, since
-- we don't encode it into the Haskell types themselves. For clarity,
-- we do note the typing environments for the open terms via comments.
-- TODO: should we tag the @abt@ type to capture whether the use
-- sites must/must-not be 'Open' terms? Or is the well-formedness
-- check sufficient?
--
-- BUG: we need the 'Functor21' instance to be strict, in order to guaranteee timely throwing of exceptions in 'subst'.
data AST :: ([Hakaru] -> Hakaru -> *) -> Hakaru -> * where

    -- -- Standard lambda calculus stuff
    Lam_    :: abt '[ a ] b -> AST abt (a ':-> b)
    App_    :: abt '[] (a ':-> b) -> abt '[] a -> AST abt b
    Let_    :: abt '[] a -> abt '[ a ] b -> AST abt b
    -- TODO: a general \"@let*@\" version of let-binding so we can have mutual recursion
    Fix_    :: abt '[ a ] a -> AST abt a
    -- | Explicitly given type annotations. (For the other
    -- change-of-direction rule in bidirectional type checking.)
    -- N.B., storing a 'Proxy' isn't enough; we need the 'Sing'.
    Ann_    :: !(Sing a) -> abt '[] a -> AST abt a


    -- -- Primitive operators
    PrimOp_ :: !(PrimOp a) -> AST abt a
    NaryOp_ :: !(NaryOp a) -> !(Seq (abt '[] a)) -> AST abt a


    -- -- Primitive atomic types: their values and coercions
    Value_      :: !(Value a)                   -> AST abt a
    CoerceTo_   :: !(Coercion a b) -> abt '[] a -> AST abt b
    UnsafeFrom_ :: !(Coercion a b) -> abt '[] b -> AST abt a
    -- TODO: add something like @SafeFrom_ :: Coercion a b -> abt b -> AST abt ('HMaybe a)@ so we can capture the safety of patterns like @if_ (0 <= x) (let x_ = unsafeFrom signed x in...) (...)@ Of course, since we're just going to do case analysis on the result; why not make it a binding form directly?
    -- TODO: we'll probably want some more general thing to capture these sorts of patterns. For example, in the default implementation of Uniform we see: @if_ (lo < x && x < hi) (... unsafeFrom_ signed (hi - lo) ...) (...)@

    -- We have the constructors for arrays here, so that they're grouped together with our other constructors 'Value_' and 'Datum_'.
    Empty_ :: AST abt ('HArray a)
    -- TODO: do we really need this to be a binding form, or could it take a Hakaru function for the second argument?
    Array_ :: abt '[] 'HNat -> abt '[ 'HNat ] a -> AST abt ('HArray a)

    -- -- User-defined data types
    -- | A data constructor applied to some expressions. N.B., this
    -- definition only accounts for data constructors which are
    -- fully saturated. Unsaturated constructors will need to be
    -- eta-expanded.
    Datum_
        :: {-# UNPACK #-} !(Datum (abt '[]) ('HData t (Code t)))
        -> AST abt ('HData t (Code t))

    -- | Generic case-analysis (via ABTs and Structural Focalization).
    Case_ :: abt '[] a -> [Branch a abt b] -> AST abt b


    -- -- Mochastic stuff
    -- TODO: should Dirac move back here?
    -- | Primitive operators which generate measures.
    Measure_ :: !(Measure a) -> AST abt a
    -- TODO: find a name so this doesn't conflict with ABT's Bind
    Bind_
        :: abt '[] ('HMeasure a)
        -> abt '[ a ] ('HMeasure b)
        -> AST abt ('HMeasure b)
    Superpose_
        :: [(abt '[] 'HProb, abt '[] ('HMeasure a))]
        -> AST abt ('HMeasure a)


----------------------------------------------------------------
-- N.B., having a @singAST :: AST abt a -> Sing a@ doesn't make
-- sense: That's what 'inferType' is for, but not all terms can be
-- inferred; some must be checked... Similarly, we can't derive
-- Read, since that's what typechecking is all about.

-- BUG: deriving instance (forall b. Eq (abt b)) => Eq (AST abt a)

instance Show2 abt => Show1 (AST abt) where
    showsPrec1 p t =
        case t of
        Lam_    e            -> showParen_2   p "Lam_"    e
        App_    e1 e2        -> showParen_22  p "App_"    e1 e2
        Let_    e1 e2        -> showParen_22  p "Let_"    e1 e2
        Fix_    e            -> showParen_2   p "Fix_"    e
        Ann_    a e          -> showParen_02  p "Ann_"    a  e
        PrimOp_ o            -> showParen_0   p "PrimOp_" o
        NaryOp_ o es         ->
            showParen (p > 9)
                ( showString "NaryOp_ "
                . showsPrec  11 o
                . showString " "
                . showParen True
                    ( showString "Seq.fromList "
                    . showList2 (F.toList es)
                    )
                )
        Value_      v        -> showParen_0   p "Value_"      v
        CoerceTo_   c e      -> showParen_02  p "CoerceTo_"   c e
        UnsafeFrom_ c e      -> showParen_02  p "UnsafeFrom_" c e
        Empty_               -> showString      "Empty_"
        Array_      e1 e2    -> showParen_22  p "Array_"      e1 e2
-- BUG: with 'showParen_1' could not deduce (Show1 (abt '[])) from (Show2 abt). But with 'showParen_2' could not deduce (Show2 Datum)...
--        Datum_      d        -> showParen_1   p "Datum_"      d
        Case_       e bs     ->
            showParen (p > 9)
                ( showString "Case_ "
                . showsPrec2 11 e
                . showString " "
                . showList1 bs
                )
        Measure_   o         -> showParen_0   p "Measure_" o
        Bind_      e1 e2     -> showParen_22  p "Bind_"   e1 e2
        Superpose_ pes       ->
            showParen (p > 9)
                ( showString "Superpose_ "
                . showListWith
                    (\(e1,e2) -> showTuple [shows2 e1, shows2 e2])
                    pes
                )

instance Show2 abt => Show (AST abt a) where
    showsPrec = showsPrec1
    show      = show1


----------------------------------------------------------------
instance Functor21 AST where
    fmap21 f (Lam_        e)        = Lam_        (f e)
    fmap21 f (App_        e1 e2)    = App_        (f e1) (f e2)
    fmap21 f (Let_        e1 e2)    = Let_        (f e1) (f e2)
    fmap21 f (Fix_        e)        = Fix_        (f e)
    fmap21 f (Ann_        p  e)     = Ann_        p      (f e)
    fmap21 _ (PrimOp_     o)        = PrimOp_     o
    fmap21 f (NaryOp_     o  es)    = NaryOp_     o      (fmap f es)
    fmap21 _ (Value_      v)        = Value_      v
    fmap21 f (CoerceTo_   c  e)     = CoerceTo_   c      (f e)
    fmap21 f (UnsafeFrom_ c  e)     = UnsafeFrom_ c      (f e)
    fmap21 _ Empty_                 = Empty_
    fmap21 f (Array_      e1 e2)    = Array_      (f e1) (f e2)
    fmap21 f (Datum_      d)        = Datum_      (fmap11 f d)
    fmap21 f (Case_       e  bs)    = Case_       (f e)  (map (fmap21 f) bs)
    fmap21 _ (Measure_    o)        = Measure_    o
    fmap21 f (Bind_       e1 e2)    = Bind_       (f e1) (f e2)
    fmap21 f (Superpose_  pes)      = Superpose_  (map (f *** f) pes)


----------------------------------------------------------------
instance Foldable21 AST where
    foldMap21 f (Lam_        e)        = f e
    foldMap21 f (App_        e1 e2)    = f e1 `mappend` f e2
    foldMap21 f (Let_        e1 e2)    = f e1 `mappend` f e2
    foldMap21 f (Fix_        e)        = f e
    foldMap21 f (Ann_        _  e)     = f e
    foldMap21 _ (PrimOp_     _)        = mempty
    foldMap21 f (NaryOp_     _  es)    = F.foldMap f es
    foldMap21 _ (Value_ _)             = mempty
    foldMap21 f (CoerceTo_   _  e)     = f e
    foldMap21 f (UnsafeFrom_ _  e)     = f e
    foldMap21 _ Empty_                 = mempty
    foldMap21 f (Array_      e1 e2)    = f e1 `mappend` f e2
    foldMap21 f (Datum_      d)        = foldMap11 f d
    foldMap21 f (Case_       e  bs)    = f e  `mappend` F.foldMap (foldMap21 f) bs
    foldMap21 _ (Measure_    _)        = mempty
    foldMap21 f (Bind_       e1 e2)    = f e1 `mappend` f e2
    foldMap21 f (Superpose_  pes)      = F.foldMap (\(e1,e2) -> f e1 `mappend` f e2) pes

----------------------------------------------------------------
----------------------------------------------------------- fin.
