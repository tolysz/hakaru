{-# LANGUAGE CPP
           , GADTs
           , DataKinds
           , KindSignatures
           , MultiParamTypeClasses
           , FunctionalDependencies
           , ScopedTypeVariables
           , FlexibleContexts
           , RankNTypes
           , TypeSynonymInstances
           , FlexibleInstances
           #-}

{-# OPTIONS_GHC -Wall -fwarn-tabs #-}
----------------------------------------------------------------
--                                                    2015.11.23
-- |
-- Module      :  Language.Hakaru.Lazy
-- Copyright   :  Copyright (c) 2015 the Hakaru team
-- License     :  BSD3
-- Maintainer  :  wren@community.haskell.org
-- Stability   :  experimental
-- Portability :  GHC-only
--
-- Lazy partial evaluation.
--
-- BUG: completely gave up on structure sharing. Need to add that back in. cf., @gvidal-lopstr07lncs.pdf@ for an approach much like my old one.
----------------------------------------------------------------
module Language.Hakaru.Lazy
    (
    -- * Lazy partial evaluation
      MeasureEvaluator
    , TermEvaluator
    , evaluate
    -- ** Helper functions
    , update

    -- ** Helpers that should really go away
    , Interp(..), reifyPair
    ) where

import           Prelude                hiding (id, (.))
import           Control.Category       (Category(..))
#if __GLASGOW_HASKELL__ < 710
import           Data.Functor           ((<$>))
#endif
import qualified Data.Traversable       as T
import           Control.Monad          ((<=<))
import           Control.Monad.Identity (Identity, runIdentity)
import           Data.Sequence          (Seq)
import qualified Data.Sequence          as Seq
import qualified Data.Text              as Text
import           Data.Number.LogFloat   (LogFloat, logFloat, fromLogFloat)

import Language.Hakaru.Syntax.IClasses
import Language.Hakaru.Syntax.HClasses
import Language.Hakaru.Syntax.Nat
import Language.Hakaru.Syntax.DataKind
import Language.Hakaru.Syntax.Sing
import Language.Hakaru.Syntax.TypeOf
import Language.Hakaru.Syntax.AST
import Language.Hakaru.Syntax.Datum
import Language.Hakaru.Syntax.DatumCase
import Language.Hakaru.Syntax.ABT
import Language.Hakaru.Syntax.Coercion
import Language.Hakaru.Lazy.Types
import qualified Language.Hakaru.Syntax.Prelude as P
import qualified Language.Hakaru.Expect         as E

----------------------------------------------------------------
----------------------------------------------------------------
-- TODO: (eventually) accept an argument dictating the evaluation
-- strategy (HNF, WHNF, full-beta NF,...). The strategy value should
-- probably be a family of singletons, where the type-level strategy
-- @s@ is also an index on the 'Context' and (the renamed) 'Whnf'.
-- That way we don't need to define a bunch of variant 'Context',
-- 'Statement', and 'Whnf' data types; but rather can use indexing
-- to select out subtypes of the generic versions.


-- | A function for \"performing\" an 'HMeasure' monadic action.
-- This could mean actual random sampling, or simulated sampling
-- by generating a new term and returning the newly bound variable,
-- or anything else.
type MeasureEvaluator abt m =
    forall a. abt '[] ('HMeasure a) -> m (Whnf abt a)


-- | A function for evaluating any term to weak-head normal form.
type TermEvaluator abt m =
    forall a. abt '[] a -> m (Whnf abt a)


-- | Lazy partial evaluation with a given \"perform\" function.
evaluate
    :: forall abt m
    .  (ABT AST abt, EvaluationMonad abt m)
    => MeasureEvaluator abt m
    -> TermEvaluator    abt m
evaluate perform = evaluate_
    where
    -- TODO: At present, whenever we residualize a case expression we'll
    -- generate a 'Neutral' term which will, when run, repeat the work
    -- we're doing in the evaluation here. We could eliminate this
    -- redundancy by introducing a new variable for @e@ each time this
    -- function is called--- if only we had some way of getting those
    -- variables put into the right place for when we residualize the
    -- original scrutinee...
    --
    -- N.B., 'DatumEvaluator' is a rank-2 type so it requires a signature
    evaluateDatum :: DatumEvaluator abt m
    evaluateDatum e = viewWhnfDatum <$> evaluate_ e

    evaluate_ :: TermEvaluator abt m
    evaluate_ e0 =
      caseVarSyn e0 (update perform evaluate_) $ \t ->
        case t of
        -- Things which are already WHNFs
        Literal_ v               -> return . Head_ $ WLiteral v
        Datum_ d                 -> return . Head_ $ WDatum d
        Empty_                   -> return . Head_ $ WEmpty
        Array_ e1 e2             -> return . Head_ $ WArray e1 e2
        Lam_  :$ e1 :* End       -> return . Head_ $ WLam   e1
        Dirac :$ e1 :* End       -> return . Head_ $ WDirac e1
        MBind :$ e1 :* e2 :* End -> return . Head_ $ WMBind e1 e2
        MeasureOp_ o :$ es       -> return . Head_ $ WMeasureOp o es
        Superpose_ pes           -> return . Head_ $ WSuperpose pes
        -- We don't bother evaluating these, even though we could...
        Integrate :$ e1 :* e2 :* e3 :* End ->
            return . Head_ $ WIntegrate e1 e2 e3
        Summate   :$ e1 :* e2 :* e3 :* End ->
            return . Head_ $ WSummate   e1 e2 e3


        -- Everything else needs some evaluation

        App_ :$ e1 :* e2 :* End -> do
            w1 <- evaluate_ e1
            case w1 of
                Neutral e1' -> return . Neutral $ P.app e1' e2
                Head_   v1  -> evaluateApp v1
            where
            evaluateApp (WAnn _ v) = evaluateApp v
            evaluateApp (WLam f)   =
                -- call-by-name:
                caseBind f $ \x f' ->
                push (SLet x $ Thunk e2) f' evaluate_
            evaluateApp _ = error "evaluate{App_}: the impossible happened"

        Let_ :$ e1 :* e2 :* End ->
            caseBind e2 $ \x e2' ->
                push (SLet x $ Thunk e1) e2' evaluate_

        Ann_      typ :$ e1 :* End -> ann           typ <$> evaluate_ e1
        CoerceTo_   c :$ e1 :* End -> coerceTo_Whnf   c <$> evaluate_ e1
        UnsafeFrom_ c :$ e1 :* End -> unsafeFrom_Whnf c <$> evaluate_ e1

        -- TODO: will maybe clean up the code to map 'evaluate' over @es@ before calling the evaluateFooOp helpers?
        NaryOp_  o    es -> evaluateNaryOp  evaluate_ o es
        ArrayOp_ o :$ es -> evaluateArrayOp evaluate_ o es
        PrimOp_  o :$ es -> evaluatePrimOp  evaluate_ o es

        -- BUG: avoid the chance of looping in case 'E.expect' residualizes!
        -- TODO: use 'evaluate' in 'E.expect' for the evaluation of @e1@
        Expect :$ e1 :* e2 :* End ->
            evaluate_ . E.expect e1 $ \e3 ->
                syn (Let_ :$ e3 :* e2 :* End)

        -- TODO: rather than throwing a Haskell error, instead
        -- capture the possibility of failure in the 'EvaluationMonad'
        -- monad.
        Case_ e bs -> do
            match <- matchBranches evaluateDatum e bs
            case match of
                Nothing ->
                    -- TODO: print more info about where this happened
                    error "evaluate: non-exhaustive patterns in case!"
                Just (GotStuck, _) ->
                    return . Neutral . syn $ Case_ e bs
                Just (Matched ss Nil1, body) ->
                    pushes (toStatements ss) body evaluate_

        _ -> error "evaluate: the impossible happened"


type DList a = [a] -> [a]

toStatements :: DList (Assoc abt) -> [Statement abt]
toStatements ss = map (\(Assoc x e) -> SLet x $ Thunk e) (ss [])


----------------------------------------------------------------
-- TODO: figure out how to abstract this so it can be reused by
-- 'constrainValue'. Especially the 'SBranch case of 'step'
--
-- TODO: we could speed up the case for free variables by having
-- the 'Context' also keep track of the largest free var. That way,
-- we can just check up front whether @varID x < nextFreeVarID@.
-- Of course, we'd have to make sure we've sufficiently renamed all
-- bound variables to be above @nextFreeVarID@; but then we have to
-- do that anyways.
update
    :: (ABT AST abt, EvaluationMonad abt m)
    => MeasureEvaluator abt m
    -> TermEvaluator    abt m
    -> Variable a
    -> m (Whnf abt a)
update perform evaluate_ = \x ->
    -- If we get 'Nothing', then it turns out @x@ is a free variable
    fmap (maybe (Neutral $ var x) id) . select x $ \s ->
        case s of
        SBind y e -> do
            Refl <- varEq x y
            Just $ do
                w <- perform $ caseLazy e fromWhnf id
                unsafePush (SLet x $ Whnf_ w)
                return w
        SLet y e -> do
            Refl <- varEq x y
            Just $ do
                w <- caseLazy e return evaluate_
                unsafePush (SLet x $ Whnf_ w)
                return w
        SWeight _ -> Nothing
        SIndex y e1 e2 -> do
            Refl <- varEq x y
            Just $ do
                error "TODO: update{SIndex}"
                {-
                w1 <- caseLazy e1 return evaluate_
                case tryReify w1 of
                    Just n1 -> do
                        checkAssert (0 <= n1)
                        w2 <- caseLazy e2 return evaluate_
                        case tryReify w2 of
                            Just n2 -> checkAssert (n1 < n2)
                            Nothing -> emitAssert (P.nat_ n1 P.< fromWhnf w2)
                    Nothing -> do
                        -- if very strict, then force @e2@ too
                        z <- emitLet (fromWhnf w1)
                        emitAssert (P.zero P.<= z P.&& z P.< fromLazy e2)
                unsafePush (SLet x $ Whnf_ w1) -- TODO: maybe save @w2@ too, to minimize work on reentry? Or maybe we should just SLet-bind the @e2@ before we push the original SIndex, so it happens automagically...
                return w1
                -}


----------------------------------------------------------------
-- if not @mustCheck (fromWhnf w1)@, then could in principle eliminate
-- the annotation; though it might be here so that it'll actually
-- get pushed down to somewhere it's needed later on, so it's best
-- to play it safe and leave it in.
ann :: (ABT AST abt) => Sing a -> Whnf abt a -> Whnf abt a
ann typ (Neutral e) = Neutral $ syn (Ann_ typ :$ e :* End)
ann typ (Head_   v) = Head_   $ WAnn typ v


-- TODO: cancellation
-- TODO: value\/constant coercion
-- TODO: better unify the two cases of Whnf
-- TODO: avoid namespace pollution by introduceing a class for these?
coerceTo_Whnf :: (ABT AST abt) => Coercion a b -> Whnf abt a -> Whnf abt b
coerceTo_Whnf c w =
    case w of
    Neutral e ->
        Neutral . maybe (P.coerceTo_ c e) id
            $ caseVarSyn e (const Nothing) $ \t ->
                case t of
                -- UnsafeFrom_ c' :$ es' -> TODO: cancellation
                CoerceTo_ c' :$ es' ->
                    case es' of
                    e' :* End -> Just $ P.coerceTo_ (c . c') e'
                    _ -> error "coerceTo_Whnf: the impossible happened"
                _ -> Nothing
    Head_ v ->
        case v of
        -- WUnsafeFrom c' v' -> TODO: cancellation
        WCoerceTo c' v' -> Head_ $ WCoerceTo (c . c') v'
        _               -> Head_ $ WCoerceTo c v


unsafeFrom_Whnf :: (ABT AST abt) => Coercion a b -> Whnf abt b -> Whnf abt a
unsafeFrom_Whnf c w =
    case w of
    Neutral e ->
        Neutral . maybe (P.unsafeFrom_ c e) id
            $ caseVarSyn e (const Nothing) $ \t ->
                case t of
                -- CoerceTo_ c' :$ es' -> TODO: cancellation
                UnsafeFrom_ c' :$ es' ->
                    case es' of
                    e' :* End -> Just $ P.unsafeFrom_ (c' . c) e'
                    _ -> error "unsafeFrom_Whnf: the impossible happened"
                _ -> Nothing
    Head_ v ->
        case v of
        -- WCoerceTo c' v' -> TODO: cancellation
        WUnsafeFrom c' v' -> Head_ $ WUnsafeFrom (c' . c) v'
        _                 -> Head_ $ WUnsafeFrom c v


-- TODO: move to Coercion.hs
-- TODO: add a class in Coercion.hs to avoid namespace pollution for all these sorts of things...
-- TODO: first optimize the @Coercion a b@ to choose the most desirable of many equivalent paths?
coerceTo_Literal :: Coercion a b -> Literal a -> Literal b
coerceTo_Literal CNil         v = v
coerceTo_Literal (CCons c cs) v = coerceTo_Literal cs (step c v)
    where
    step :: PrimCoercion a b -> Literal a -> Literal b
    step (Signed     HRing_Int)        (LNat  n) = LInt  (nat2int   n)
    step (Signed     HRing_Real)       (LProb p) = LReal (prob2real p)
    step (Continuous HContinuous_Prob) (LNat  n) = LProb (nat2prob  n)
    step (Continuous HContinuous_Real) (LInt  i) = LReal (int2real  i)
    step _ _ = error "coerceTo_Literal: the impossible happened"

    -- HACK: type signatures needed to avoid defaulting to 'Integer'
    nat2int   :: Nat -> Int
    nat2int   = fromIntegral . fromNat
    nat2prob  :: Nat -> LogFloat
    nat2prob  = logFloat . fromIntegral . fromNat -- N.B., costs a 'log'
    prob2real :: LogFloat -> Double
    prob2real = fromLogFloat -- N.B., costs an 'exp' and may underflow
    int2real  :: Int -> Double
    int2real  = fromIntegral


-- TODO: how to handle the errors? Generate error code in hakaru? capture it in a monad?
unsafeFrom_Literal :: Coercion a b -> Literal b -> Literal a
unsafeFrom_Literal CNil         v = v
unsafeFrom_Literal (CCons c cs) v = step c (unsafeFrom_Literal cs v)
    where
    step :: PrimCoercion a b -> Literal b -> Literal a
    step (Signed     HRing_Int)        (LInt  i) = LNat  (int2nat   i)
    step (Signed     HRing_Real)       (LReal r) = LProb (real2prob r)
    step (Continuous HContinuous_Prob) (LProb p) = LNat  (prob2nat  p)
    step (Continuous HContinuous_Real) (LReal r) = LInt  (real2int  r)
    step _ _ = error "unsafeFrom_Literal: the impossible happened"

    -- HACK: type signatures needed to avoid defaulting to 'Integer'
    int2nat   :: Int -> Nat
    int2nat   = unsafeNat -- TODO: maybe change the error message...
    prob2nat  :: LogFloat -> Nat
    prob2nat  = error "TODO: prob2nat" -- BUG: impossible unless using Rational...
    real2prob :: Double -> LogFloat
    real2prob = logFloat -- TODO: maybe change the error message...
    real2int  :: Double -> Int
    real2int  = error "TODO: real2int" -- BUG: impossible unless using Rational...


----------------------------------------------------------------
-- BUG: need to improve the types so they can capture polymorphic data types
-- BUG: this is a **really gross** hack. If we can avoid it, we should!!!
class Interp a a' | a -> a' where
    reify   :: (ABT AST abt) => Head abt a -> a'
    reflect :: (ABT AST abt) => a' -> Head abt a

instance Interp 'HNat Nat where
    reflect = WLiteral . LNat
    reify (WLiteral (LNat n)) = n
    reify (WAnn        _ v) = reify v
    reify (WCoerceTo   _ _) = error "TODO: reify{WCoerceTo}"
    reify (WUnsafeFrom _ _) = error "TODO: reify{WUnsafeFrom}"

instance Interp 'HInt Int where
    reflect = WLiteral . LInt
    reify (WLiteral (LInt i)) = i
    reify (WAnn        _ v) = reify v
    reify (WCoerceTo   _ _) = error "TODO: reify{WCoerceTo}"
    reify (WUnsafeFrom _ _) = error "TODO: reify{WUnsafeFrom}"

instance Interp 'HProb LogFloat where -- TODO: use rational instead
    reflect = WLiteral . LProb
    reify (WLiteral (LProb p))  = p
    reify (WAnn        _ v)   = reify v
    reify (WCoerceTo   _ _)   = error "TODO: reify{WCoerceTo}"
    reify (WUnsafeFrom _ _)   = error "TODO: reify{WUnsafeFrom}"
    reify (WIntegrate  _ _ _) = error "TODO: reify{WIntegrate}"
    reify (WSummate    _ _ _) = error "TODO: reify{WSummate}"

instance Interp 'HReal Double where -- TODO: use rational instead
    reflect = WLiteral . LReal
    reify (WLiteral (LReal r)) = r
    reify (WAnn        _ v) = reify v
    reify (WCoerceTo   _ _) = error "TODO: reify{WCoerceTo}"
    reify (WUnsafeFrom _ _) = error "TODO: reify{WUnsafeFrom}"


identifyDatum :: (ABT AST abt) => DatumEvaluator abt Identity
identifyDatum = return . (viewWhnfDatum <=< toWhnf)

-- HACK: this requires -XTypeSynonymInstances and -XFlexibleInstances
-- This instance does seem to work; albeit it's trivial...
instance Interp HUnit () where
    reflect () = error "TODO" -- WLiteral $ VDatum dUnit
    reify v = runIdentity $ do
        match <- matchTopPattern identifyDatum (fromHead v) pUnit Nil1
        case match of
            Just (Matched _ss Nil1) -> return ()
            _ -> error "reify{HUnit}: the impossible happened"

-- HACK: this requires -XTypeSynonymInstances and -XFlexibleInstances
-- This instance also seems to work...
instance Interp HBool Bool where
    reflect = error "TODO" -- WLiteral . VDatum . (\b -> if b then dTrue else dFalse)
    reify v = runIdentity $ do
        matchT <- matchTopPattern identifyDatum (fromHead v) pTrue Nil1
        case matchT of
            Just (Matched _ss Nil1) -> return True
            Just GotStuck -> error "reify{HBool}: the impossible happened"
            Nothing -> do
                matchF <- matchTopPattern identifyDatum (fromHead v) pFalse Nil1
                case matchF of
                    Just (Matched _ss Nil1) -> return False
                    _ -> error "reify{HBool}: the impossible happened"


-- TODO: can't we just use 'viewHeadDatum' and match on that?
reifyPair :: (ABT AST abt) => Head abt (HPair a b) -> (abt '[] a, abt '[] b)
reifyPair v =
    let impossible = error "reifyPair: the impossible happened"
        e0    = fromHead v
        n     = nextFree e0
        (a,b) = sUnPair $ typeOf e0
        x = Variable Text.empty n       a
        y = Variable Text.empty (1 + n) b

    in runIdentity $ do
        match <- matchTopPattern identifyDatum e0 (pPair PVar PVar) (Cons1 x (Cons1 y Nil1))
        case match of
            Just (Matched ss Nil1) ->
                case ss [] of
                [Assoc x' e1, Assoc y' e2] ->
                    maybe impossible id $ do
                        Refl <- varEq x x'
                        Refl <- varEq y y'
                        Just $ return (e1, e2)
                _ -> impossible
            _ -> impossible
{-
instance Interp (HPair a b) (abt '[] a, abt '[] b) where
    reflect (a,b) = P.pair a b
    reify = reifyPair

instance Interp (HEither a b) (Either (abt '[] a) (abt '[] b)) where
    reflect (Left  a) = P.left  a
    reflect (Right b) = P.right b
    reify =

instance Interp (HMaybe a) (Maybe (abt '[] a)) where
    reflect Nothing  = P.nothing
    reflect (Just a) = P.just a
    reify =

data ListHead (a :: Hakaru)
    = NilHead
    | ConsHead (abt '[] a) (abt '[] (HList a)) -- modulo scoping of @abt@

instance Interp (HList a) (ListHead a) where
    reflect []     = P.nil
    reflect (x:xs) = P.cons x xs
    reify =
-}


impl, diff, nand, nor :: Bool -> Bool -> Bool
impl x y = not x || y
diff x y = x && not y
nand x y = not (x && y)
nor  x y = not (x || y)

-- BUG: no Floating instance for LogFloat, so can't actually use this...
natRoot :: (Floating a) => a -> Nat -> a
natRoot x y = x ** recip (fromIntegral (fromNat y))


----------------------------------------------------------------
evaluateNaryOp
    :: (ABT AST abt, EvaluationMonad abt m)
    => TermEvaluator abt m
    -> NaryOp a
    -> Seq (abt '[] a)
    -> m (Whnf abt a)
evaluateNaryOp evaluate_ = \o es -> mainLoop o (evalOp o) Seq.empty es
    where
    -- TODO: there's got to be a more efficient way to do this...
    mainLoop o op ws es =
        case Seq.viewl es of
        Seq.EmptyL   -> return $
            case Seq.viewl ws of
            Seq.EmptyL         -> identityElement o -- Avoid empty naryOps
            w Seq.:< ws'
                | Seq.null ws' -> w -- Avoid singleton naryOps
                | otherwise    ->
                    Neutral . syn . NaryOp_ o $ fmap fromWhnf ws
        e Seq.:< es' -> do
            w <- evaluate_ e
            case matchNaryOp o w of
                Nothing  -> mainLoop o op (snocLoop op ws w) es'
                Just es2 -> mainLoop o op ws (es2 Seq.>< es')

    snocLoop
        :: (ABT syn abt)
        => (Head abt a -> Head abt a -> Head abt a)
        -> Seq (Whnf abt a)
        -> Whnf abt a
        -> Seq (Whnf abt a)
    snocLoop op ws w1 =
        case Seq.viewr ws of
        Seq.EmptyR    -> Seq.singleton w1
        ws' Seq.:> w2 ->
            case (w1,w2) of
            (Head_ v1, Head_ v2) -> snocLoop op ws' (Head_ (op v1 v2))
            _                    -> ws Seq.|> w1

    matchNaryOp
        :: (ABT AST abt)
        => NaryOp a
        -> Whnf abt a
        -> Maybe (Seq (abt '[] a))
    matchNaryOp o w =
        case w of
        Head_   _ -> Nothing
        Neutral e ->
            caseVarSyn e (const Nothing) $ \t ->
                case t of
                NaryOp_ o' es | o' == o -> Just es
                _                       -> Nothing

    -- TODO: move this off to Prelude.hs or somewhere...
    identityElement :: (ABT AST abt) => NaryOp a -> Whnf abt a
    identityElement o =
        case o of
        And    -> Head_ (WDatum dTrue)
        Or     -> Head_ (WDatum dFalse)
        Xor    -> Head_ (WDatum dFalse)
        Iff    -> Head_ (WDatum dTrue)
        Min  _ -> Neutral (syn (NaryOp_ o Seq.empty)) -- no identity in general (but we could do it by cases...)
        Max  _ -> Neutral (syn (NaryOp_ o Seq.empty)) -- no identity in general (but we could do it by cases...)
        -- TODO: figure out how to reuse 'P.zero' and 'P.one' here
        Sum  HSemiring_Nat  -> Head_ (WLiteral (LNat  0))
        Sum  HSemiring_Int  -> Head_ (WLiteral (LInt  0))
        Sum  HSemiring_Prob -> Head_ (WLiteral (LProb 0))
        Sum  HSemiring_Real -> Head_ (WLiteral (LReal 0))
        Prod HSemiring_Nat  -> Head_ (WLiteral (LNat  1))
        Prod HSemiring_Int  -> Head_ (WLiteral (LInt  1))
        Prod HSemiring_Prob -> Head_ (WLiteral (LProb 1))
        Prod HSemiring_Real -> Head_ (WLiteral (LReal 1))

    -- | The evaluation interpretation of each NaryOp
    evalOp :: (ABT AST abt) => NaryOp a -> Head abt a -> Head abt a -> Head abt a
    -- TODO: something more efficient\/direct if we can...
    evalOp And      v1 v2 = reflect (reify v1 && reify v2)
    evalOp Or       v1 v2 = reflect (reify v1 || reify v2)
    evalOp Xor      v1 v2 = reflect (reify v1 /= reify v2)
    evalOp Iff      v1 v2 = reflect (reify v1 == reify v2)
    {-
    evalOp (Min  _) v1 v2 = reflect (reify v1 `min` reify v2)
    evalOp (Max  _) v1 v2 = reflect (reify v1 `max` reify v2)
    evalOp (Sum  _) v1 v2 = reflect (reify v1 + reify v2)
    evalOp (Prod _) v1 v2 = reflect (reify v1 * reify v2)
    -}
    -- HACK: this is just to have something to test. We really should reduce\/remove all this boilerplate...
    evalOp (Sum  s) (WLiteral v1) (WLiteral v2) = WLiteral $ evalSum  s v1 v2
    evalOp (Prod s) (WLiteral v1) (WLiteral v2) = WLiteral $ evalProd s v1 v2
    evalOp (Sum  _) _ _ = error "evalOp: the impossible happened"
    evalOp (Prod _) _ _ = error "evalOp: the impossible happened"
    evalOp _ _ _ = error "TODO: evalOp{HBool ops, HOrd ops}"

    evalSum, evalProd :: HSemiring a -> Literal a -> Literal a -> Literal a
    evalSum  HSemiring_Nat  (LNat  n1) (LNat  n2) = LNat  (n1 + n2)
    evalSum  HSemiring_Int  (LInt  i1) (LInt  i2) = LInt  (i1 + i2)
    evalSum  HSemiring_Prob (LProb p1) (LProb p2) = LProb (p1 + p2)
    evalSum  HSemiring_Real (LReal r1) (LReal r2) = LReal (r1 + r2)
    evalSum  _ _ _ = error "evalSum: the impossible happened"
    evalProd HSemiring_Nat  (LNat  n1) (LNat  n2) = LNat  (n1 * n2)
    evalProd HSemiring_Int  (LInt  i1) (LInt  i2) = LInt  (i1 * i2)
    evalProd HSemiring_Prob (LProb p1) (LProb p2) = LProb (p1 * p2)
    evalProd HSemiring_Real (LReal r1) (LReal r2) = LReal (r1 * r2)
    evalProd _ _ _ = error "evalProd: the impossible happened"


----------------------------------------------------------------
evaluateArrayOp
    :: ( ABT AST abt, EvaluationMonad abt m
       , typs ~ UnLCs args, args ~ LCs typs)
    => TermEvaluator abt m
    -> ArrayOp typs a
    -> SArgs abt args
    -> m (Whnf abt a)
evaluateArrayOp evaluate_ o es =
    case (o,es) of
    (Index _, e1 :* e2 :* End) -> do
        w1 <- evaluate_ e1
        case w1 of
            Neutral e1' ->
                return . Neutral $ syn (ArrayOp_ o :$ e1' :* e2 :* End)
            Head_   v1  ->
                case head2array v1 of
                Nothing ->
                    error "TODO: use bot"
                Just WAEmpty ->
                    error "evaluate: indexing into empty array!"
                Just (WAArray e3 e4) ->
                    -- a call-by-name approach to indexing:
                    caseBind e4 $ \x e4' ->
                        push (SIndex x (Thunk e2) (Thunk e3)) e4' evaluate_

    (Size _, e1 :* End) -> do
        w1 <- evaluate_ e1
        case w1 of
            Neutral e1' -> return . Neutral $ syn (ArrayOp_ o :$ e1' :* End)
            Head_   v1  ->
                case head2array v1 of
                Nothing             -> error "TODO: use bot"
                Just WAEmpty        -> return . Head_ $ WLiteral (LNat 0)
                Just (WAArray e3 _) -> evaluate_ e3

    (Reduce _, e1 :* e2 :* e3 :* End) ->
        error "TODO: evaluateArrayOp{Reduce}"

    _ -> error "evaluateArrayOp: the impossible happened"


data ArrayHead :: ([Hakaru] -> Hakaru -> *) -> Hakaru -> * where
    WAEmpty :: ArrayHead abt a
    WAArray
        :: !(abt '[] 'HNat)
        -> !(abt '[ 'HNat] a)
        -> ArrayHead abt a

head2array :: Head abt ('HArray a) -> Maybe (ArrayHead abt a)
head2array WEmpty         = Just WAEmpty
head2array (WArray e1 e2) = Just (WAArray e1 e2)
head2array (WAnn _ w)     = head2array w
head2array _ = error "head2array: the impossible happened"


----------------------------------------------------------------
evaluatePrimOp
    :: forall abt m typs args a
    .  ( ABT AST abt, EvaluationMonad abt m
       , typs ~ UnLCs args, args ~ LCs typs)
    => TermEvaluator abt m
    -> PrimOp typs a
    -> SArgs abt args
    -> m (Whnf abt a)
evaluatePrimOp evaluate_ = go
    where
    rr1 :: forall b b' c c'
        .  (Interp b b', Interp c c')
        => (b' -> c')
        -> (abt '[] b -> abt '[] c)
        -> abt '[] b
        -> m (Whnf abt c)
    rr1 f' f e = do
        w <- evaluate_ e
        return $
            case w of
            Neutral e' -> Neutral $ f e'
            Head_   v  -> Head_ . reflect $ f' (reify v)

    rr2 :: forall b b' c c' d d'
        .  (Interp b b', Interp c c', Interp d d')
        => (b' -> c' -> d')
        -> (abt '[] b -> abt '[] c -> abt '[] d)
        -> abt '[] b
        -> abt '[] c
        -> m (Whnf abt d)
    rr2 f' f e1 e2 = do
        w1 <- evaluate_ e1
        w2 <- evaluate_ e2
        return $
            case w1 of
            Neutral e1' -> Neutral $ f e1' (fromWhnf w2)
            Head_   v1  ->
                case w2 of
                Neutral e2' -> Neutral $ f (fromWhnf w1) e2'
                Head_   v2  -> Head_ . reflect $ f' (reify v1) (reify v2)

    primOp2_
        :: forall b c d
        .  PrimOp '[ b, c ] d -> abt '[] b -> abt '[] c -> abt '[] d
    primOp2_ o e1 e2 = syn (PrimOp_ o :$ e1 :* e2 :* End)

    -- TODO: something more efficient\/direct if we can...
    go Not  (e1 :* End)       = rr1 not  P.not  e1
    go Impl (e1 :* e2 :* End) = rr2 impl (primOp2_ Impl) e1 e2
    go Diff (e1 :* e2 :* End) = rr2 diff (primOp2_ Diff) e1 e2
    go Nand (e1 :* e2 :* End) = rr2 nand P.nand e1 e2
    go Nor  (e1 :* e2 :* End) = rr2 nor  P.nor  e1 e2
    {-
    -- TODO: all our magic constants (Pi, Infty,...) should be bundled together under one AST constructor called something like @Constant@; that way we can group them in the 'Head' like we do for values.
    go Pi        End               = return (Head_ HPi)
    -}
    -- TODO: don't actually evaluate these, to avoid fuzz issues
    go Sin       (e1 :* End)       = rr1 sin   P.sin   e1
    go Cos       (e1 :* End)       = rr1 cos   P.cos   e1
    go Tan       (e1 :* End)       = rr1 tan   P.tan   e1
    go Asin      (e1 :* End)       = rr1 asin  P.asin  e1
    go Acos      (e1 :* End)       = rr1 acos  P.acos  e1
    go Atan      (e1 :* End)       = rr1 atan  P.atan  e1
    go Sinh      (e1 :* End)       = rr1 sinh  P.sinh  e1
    go Cosh      (e1 :* End)       = rr1 cosh  P.cosh  e1
    go Tanh      (e1 :* End)       = rr1 tanh  P.tanh  e1
    go Asinh     (e1 :* End)       = rr1 asinh P.asinh e1
    go Acosh     (e1 :* End)       = rr1 acosh P.acosh e1
    go Atanh     (e1 :* End)       = rr1 atanh P.atanh e1
    {-
    -- TODO: deal with how we have better types for these three ops than Haskell does...
    go RealPow   (e1 :* e2 :* End) = rr2 (**) (P.**) e1 e2
    go Exp       (e1 :* End)       = rr1 exp   P.exp e1
    go Log       (e1 :* End)       = rr1 log   P.log e1
    go Infinity         End        = return (Head_ HInfinity)
    go NegativeInfinity End        = return (Head_ HNegativeInfinity)
    go GammaFunc   (e1 :* End)             =
    go BetaFunc    (e1 :* e2 :* End)       =
    -- TODO: deal with polymorphism issues
    go (Equal theOrd) (e1 :* e2 :* End) = rr2 (==) (P.==) e1 e2
    go (Less  theOrd) (e1 :* e2 :* End) = rr2 (<)  (P.<)  e1 e2
    -}
    go (NatPow theSemi) (e1 :* e2 :* End) =
        case theSemi of
        HSemiring_Nat    -> rr2 (\v1 v2 -> v1 ^ fromNat v2) (P.^) e1 e2
        HSemiring_Int    -> rr2 (\v1 v2 -> v1 ^ fromNat v2) (P.^) e1 e2
        HSemiring_Prob   -> rr2 (\v1 v2 -> v1 ^ fromNat v2) (P.^) e1 e2
        HSemiring_Real   -> rr2 (\v1 v2 -> v1 ^ fromNat v2) (P.^) e1 e2
    go (Negate theRing) (e1 :* End) =
        case theRing of
        HRing_Int        -> rr1 negate P.negate e1
        HRing_Real       -> rr1 negate P.negate e1
    go (Abs    theRing) (e1 :* End) = 
        case theRing of
        HRing_Int        -> rr1 (unsafeNat . abs) P.abs_ e1
        HRing_Real       -> rr1 (logFloat  . abs) P.abs_ e1
    go (Signum theRing) (e1 :* End) =
        case theRing of
        HRing_Int        -> rr1 signum P.signum e1
        HRing_Real       -> rr1 signum P.signum e1
    go (Recip  theFractional) (e1 :* End) =
        case theFractional of
        HFractional_Prob -> rr1 recip  P.recip  e1
        HFractional_Real -> rr1 recip  P.recip  e1
    {-
    go (NatRoot theRadical) (e1 :* e2 :* End) =
        case theRadical of
        HRadical_Prob -> rr2 natRoot (flip P.thRootOf) e1 e2
    go (Erf theContinuous) (e1 :* End) =
        case theContinuous of
        HContinuous_Prob -> rr1 erf P.erf e1
        HContinuous_Real -> rr1 erf P.erf e1
    -}
    go _ _ = error "TODO: finish evaluatePrimOp"


----------------------------------------------------------------
----------------------------------------------------------- fin.
