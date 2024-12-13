{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE RecursiveDo #-}

module GHC.Tc.Solver.Canonical(
     canonicalize,
     unifyWanted,
     makeSuperClasses,
     StopOrContinue(..), stopWith, continueWith, andWhenContinue,
     rewriteEqEvidence,
     solveCallStack    -- For GHC.Tc.Solver
  ) where

import GHC.Prelude

import GHC.Tc.Types.Constraint
import GHC.Core.Predicate
import GHC.Tc.Types.Origin
import GHC.Tc.Utils.Unify
import GHC.Tc.Utils.TcType
import GHC.Core.Type
import GHC.Tc.Solver.Rewrite
import GHC.Tc.Solver.Monad
import GHC.Tc.Solver.InertSet
import GHC.Tc.Types.Evidence
import GHC.Tc.Types.EvTerm
import GHC.Core.Class
import GHC.Core.DataCon ( dataConName )
import GHC.Core.TyCon
import GHC.Core.Multiplicity
import GHC.Core.TyCo.Rep   -- cleverly decomposes types, good for completeness checking
import GHC.Core.Coercion
import GHC.Core.Coercion.Axiom
import GHC.Core.Reduction
import GHC.Core
import GHC.Types.Id( mkTemplateLocals )
import GHC.Core.FamInstEnv ( FamInstEnvs )
import GHC.Tc.Instance.Family ( tcTopNormaliseNewTypeTF_maybe )
import GHC.Types.Var
import GHC.Types.Var.Env( mkInScopeSet )
import GHC.Types.Var.Set( delVarSetList, anyVarSet )
import GHC.Utils.Outputable
import GHC.Utils.Panic
import GHC.Utils.Panic.Plain
import GHC.Builtin.Types ( anyTypeOfKind )
import GHC.Types.Name.Set
import GHC.Types.Name.Reader
import GHC.Hs.Type( HsIPName(..) )
import GHC.Types.Unique  ( hasKey )
import GHC.Builtin.Names ( coercibleTyConKey )

import GHC.Data.Pair
import GHC.Utils.Misc
import GHC.Data.Bag
import GHC.Utils.Monad
import GHC.Utils.Constants( debugIsOn )
import Control.Monad
import Data.Maybe ( isJust, isNothing )
import Data.List  ( zip4 )
import GHC.Types.Basic

import qualified Data.Semigroup as S
import Data.Bifunctor ( bimap )

{-
************************************************************************
*                                                                      *
*                      The Canonicaliser                               *
*                                                                      *
************************************************************************

Note [Canonicalization]
~~~~~~~~~~~~~~~~~~~~~~~

Canonicalization converts a simple constraint to a canonical form. It is
unary (i.e. treats individual constraints one at a time).

Constraints originating from user-written code come into being as
CNonCanonicals. We know nothing about these constraints. So, first:

     Classify CNonCanoncal constraints, depending on whether they
     are equalities, class predicates, or other.

Then proceed depending on the shape of the constraint. Generally speaking,
each constraint gets rewritten and then decomposed into one of several forms
(see type Ct in GHC.Tc.Types).

When an already-canonicalized constraint gets kicked out of the inert set,
it must be recanonicalized. But we know a bit about its shape from the
last time through, so we can skip the classification step.

-}

-- Top-level canonicalization
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

canonicalize :: Ct -> TcS (StopOrContinue Ct)
canonicalize (CNonCanonical { cc_ev = ev })
  = {-# SCC "canNC" #-}
    canNC ev

canonicalize (CQuantCan (QCI { qci_ev = ev, qci_pend_sc = pend_sc }))
  = canForAll ev pend_sc

canonicalize (CIrredCan { cc_ev = ev })
  = canNC ev
    -- Instead of rewriting the evidence before classifying, it's possible we
    -- can make progress without the rewrite. Try this first.
    -- For insolubles (all of which are equalities), do /not/ rewrite the arguments
    -- In #14350 doing so led entire-unnecessary and ridiculously large
    -- type function expansion.  Instead, canEqNC just applies
    -- the substitution to the predicate, and may do decomposition;
    --    e.g. a ~ [a], where [G] a ~ [Int], can decompose

canonicalize (CDictCan { cc_ev = ev, cc_class  = cls
                       , cc_tyargs = xis, cc_pend_sc = pend_sc })
  = {-# SCC "canClass" #-}
    canClass ev cls xis pend_sc

canonicalize (CEqCan { cc_ev     = ev
                     , cc_lhs    = lhs
                     , cc_rhs    = rhs
                     , cc_eq_rel = eq_rel })
  = {-# SCC "canEqLeafTyVarEq" #-}
    canEqNC ev eq_rel (canEqLHSType lhs) rhs

canNC :: CtEvidence -> TcS (StopOrContinue Ct)
canNC ev =
  case classifyPredType pred of
      ClassPred cls tys     -> do traceTcS "canEvNC:cls" (ppr cls <+> ppr tys)
                                  canClassNC ev cls tys
      EqPred eq_rel ty1 ty2 -> do traceTcS "canEvNC:eq" (ppr ty1 $$ ppr ty2)
                                  canEqNC    ev eq_rel ty1 ty2
      IrredPred {}          -> do traceTcS "canEvNC:irred" (ppr pred)
                                  canIrred ev
      ForAllPred tvs th p   -> do traceTcS "canEvNC:forall" (ppr pred)
                                  canForAllNC ev tvs th p

  where
    pred = ctEvPred ev

{-
************************************************************************
*                                                                      *
*                      Class Canonicalization
*                                                                      *
************************************************************************
-}

canClassNC :: CtEvidence -> Class -> [Type] -> TcS (StopOrContinue Ct)
-- "NC" means "non-canonical"; that is, we have got here
-- from a NonCanonical constraint, not from a CDictCan
-- Precondition: EvVar is class evidence
canClassNC ev cls tys
  | isGiven ev  -- See Note [Eagerly expand given superclasses]
  = do { sc_cts <- mkStrictSuperClasses ev [] [] cls tys
       ; emitWork sc_cts
       ; canClass ev cls tys False }

  | CtWanted { ctev_rewriters = rewriters } <- ev
  , Just ip_name <- isCallStackPred cls tys
  , isPushCallStackOrigin orig
  -- If we're given a CallStack constraint that arose from a function
  -- call, we need to push the current call-site onto the stack instead
  -- of solving it directly from a given.
  -- See Note [Overview of implicit CallStacks] in GHC.Tc.Types.Evidence
  -- and Note [Solving CallStack constraints] in GHC.Tc.Solver.Types
  = do { -- First we emit a new constraint that will capture the
         -- given CallStack.
       ; let new_loc = setCtLocOrigin loc (IPOccOrigin (HsIPName ip_name))
                            -- We change the origin to IPOccOrigin so
                            -- this rule does not fire again.
                            -- See Note [Overview of implicit CallStacks]
                            -- in GHC.Tc.Types.Evidence

       ; new_ev <- newWantedEvVarNC new_loc rewriters pred

         -- Then we solve the wanted by pushing the call-site
         -- onto the newly emitted CallStack
       ; let ev_cs = EvCsPushCall (callStackOriginFS orig)
                                  (ctLocSpan loc) (ctEvExpr new_ev)
       ; solveCallStack ev ev_cs

       ; canClass new_ev cls tys False -- No superclasses
       }

  | otherwise
  = canClass ev cls tys (has_scs cls)

  where
    has_scs cls = not (null (classSCTheta cls))
    loc  = ctEvLoc ev
    orig = ctLocOrigin loc
    pred = ctEvPred ev

solveCallStack :: CtEvidence -> EvCallStack -> TcS ()
-- Also called from GHC.Tc.Solver when defaulting call stacks
solveCallStack ev ev_cs = do
  -- We're given ev_cs :: CallStack, but the evidence term should be a
  -- dictionary, so we have to coerce ev_cs to a dictionary for
  -- `IP ip CallStack`. See Note [Overview of implicit CallStacks]
  cs_tm <- evCallStack ev_cs
  let ev_tm = mkEvCast cs_tm (wrapIP (ctEvPred ev))
  setEvBindIfWanted ev ev_tm

canClass :: CtEvidence
         -> Class -> [Type]
         -> Bool            -- True <=> un-explored superclasses
         -> TcS (StopOrContinue Ct)
-- Precondition: EvVar is class evidence

canClass ev cls tys pend_sc
  = -- all classes do *nominal* matching
    assertPpr (ctEvRole ev == Nominal) (ppr ev $$ ppr cls $$ ppr tys) $
    do { (redns@(Reductions _ xis), rewriters) <- rewriteArgsNom ev cls_tc tys
       ; let redn@(Reduction _ xi) = mkClassPredRedn cls redns
             mk_ct new_ev = CDictCan { cc_ev = new_ev
                                     , cc_tyargs = xis
                                     , cc_class = cls
                                     , cc_pend_sc = pend_sc }
       ; mb <- rewriteEvidence rewriters ev redn
       ; traceTcS "canClass" (vcat [ ppr ev
                                   , ppr xi, ppr mb ])
       ; return (fmap mk_ct mb) }
  where
    cls_tc = classTyCon cls

{- Note [The superclass story]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We need to add superclass constraints for two reasons:

* For givens [G], they give us a route to proof.  E.g.
    f :: Ord a => a -> Bool
    f x = x == x
  We get a Wanted (Eq a), which can only be solved from the superclass
  of the Given (Ord a).

* For wanteds [W], they may give useful
  functional dependencies.  E.g.
     class C a b | a -> b where ...
     class C a b => D a b where ...
  Now a [W] constraint (D Int beta) has (C Int beta) as a superclass
  and that might tell us about beta, via C's fundeps.  We can get this
  by generating a [W] (C Int beta) constraint. We won't use the evidence,
  but it may lead to unification.

See Note [Why adding superclasses can help].

For these reasons we want to generate superclass constraints for both
Givens and Wanteds. But:

* (Minor) they are often not needed, so generating them aggressively
  is a waste of time.

* (Major) if we want recursive superclasses, there would be an infinite
  number of them.  Here is a real-life example (#10318);

     class (Frac (Frac a) ~ Frac a,
            Fractional (Frac a),
            IntegralDomain (Frac a))
         => IntegralDomain a where
      type Frac a :: *

  Notice that IntegralDomain has an associated type Frac, and one
  of IntegralDomain's superclasses is another IntegralDomain constraint.

So here's the plan:

1. Eagerly generate superclasses for given (but not wanted)
   constraints; see Note [Eagerly expand given superclasses].
   This is done using mkStrictSuperClasses in canClassNC, when
   we take a non-canonical Given constraint and cannonicalise it.

   However stop if you encounter the same class twice.  That is,
   mkStrictSuperClasses expands eagerly, but has a conservative
   termination condition: see Note [Expanding superclasses] in GHC.Tc.Utils.TcType.

2. Solve the wanteds as usual, but do no further expansion of
   superclasses for canonical CDictCans in solveSimpleGivens or
   solveSimpleWanteds; Note [Danger of adding superclasses during solving]

   However, /do/ continue to eagerly expand superclasses for new /given/
   /non-canonical/ constraints (canClassNC does this).  As #12175
   showed, a type-family application can expand to a class constraint,
   and we want to see its superclasses for just the same reason as
   Note [Eagerly expand given superclasses].

3. If we have any remaining unsolved wanteds
        (see Note [When superclasses help] in GHC.Tc.Types.Constraint)
   try harder: take both the Givens and Wanteds, and expand
   superclasses again.  See the calls to expandSuperClasses in
   GHC.Tc.Solver.simpl_loop and solveWanteds.

   This may succeed in generating (a finite number of) extra Givens,
   and extra Wanteds. Both may help the proof.

3a An important wrinkle: only expand Givens from the current level.
   Two reasons:
      - We only want to expand it once, and that is best done at
        the level it is bound, rather than repeatedly at the leaves
        of the implication tree
      - We may be inside a type where we can't create term-level
        evidence anyway, so we can't superclass-expand, say,
        (a ~ b) to get (a ~# b).  This happened in #15290.

4. Go round to (2) again.  This loop (2,3,4) is implemented
   in GHC.Tc.Solver.simpl_loop.

The cc_pend_sc flag in a CDictCan records whether the superclasses of
this constraint have been expanded.  Specifically, in Step 3 we only
expand superclasses for constraints with cc_pend_sc set to true (i.e.
isPendingScDict holds).

Why do we do this?  Two reasons:

* To avoid repeated work, by repeatedly expanding the superclasses of
  same constraint,

* To terminate the above loop, at least in the -XNoUndecidableSuperClasses
  case.  If there are recursive superclasses we could, in principle,
  expand forever, always encountering new constraints.

When we take a CNonCanonical or CIrredCan, but end up classifying it
as a CDictCan, we set the cc_pend_sc flag to False.

Note [Superclass loops]
~~~~~~~~~~~~~~~~~~~~~~~
Suppose we have
  class C a => D a
  class D a => C a

Then, when we expand superclasses, we'll get back to the self-same
predicate, so we have reached a fixpoint in expansion and there is no
point in fruitlessly expanding further.  This case just falls out from
our strategy.  Consider
  f :: C a => a -> Bool
  f x = x==x
Then canClassNC gets the [G] d1: C a constraint, and eager emits superclasses
G] d2: D a, [G] d3: C a (psc).  (The "psc" means it has its sc_pend flag set.)
When processing d3 we find a match with d1 in the inert set, and we always
keep the inert item (d1) if possible: see Note [Replacement vs keeping] in
GHC.Tc.Solver.Interact.  So d3 dies a quick, happy death.

Note [Eagerly expand given superclasses]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
In step (1) of Note [The superclass story], why do we eagerly expand
Given superclasses by one layer?  (By "one layer" we mean expand transitively
until you meet the same class again -- the conservative criterion embodied
in expandSuperClasses.  So a "layer" might be a whole stack of superclasses.)
We do this eagerly for Givens mainly because of some very obscure
cases like this:

   instance Bad a => Eq (T a)

   f :: (Ord (T a)) => blah
   f x = ....needs Eq (T a), Ord (T a)....

Here if we can't satisfy (Eq (T a)) from the givens we'll use the
instance declaration; but then we are stuck with (Bad a).  Sigh.
This is really a case of non-confluent proofs, but to stop our users
complaining we expand one layer in advance.

Note [Instance and Given overlap] in GHC.Tc.Solver.Interact.

We also want to do this if we have

   f :: F (T a) => blah

where
   type instance F (T a) = Ord (T a)

So we may need to do a little work on the givens to expose the
class that has the superclasses.  That's why the superclass
expansion for Givens happens in canClassNC.

This same scenario happens with quantified constraints, whose superclasses
are also eagerly expanded. Test case: typecheck/should_compile/T16502b
These are handled in canForAllNC, analogously to canClassNC.

Note [Why adding superclasses can help]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Examples of how adding superclasses can help:

    --- Example 1
        class C a b | a -> b
    Suppose we want to solve
         [G] C a b
         [W] C a beta
    Then adding [W] beta~b will let us solve it.

    -- Example 2 (similar but using a type-equality superclass)
        class (F a ~ b) => C a b
    And try to sllve:
         [G] C a b
         [W] C a beta
    Follow the superclass rules to add
         [G] F a ~ b
         [W] F a ~ beta
    Now we get [W] beta ~ b, and can solve that.

    -- Example (tcfail138)
      class L a b | a -> b
      class (G a, L a b) => C a b

      instance C a b' => G (Maybe a)
      instance C a b  => C (Maybe a) a
      instance L (Maybe a) a

    When solving the superclasses of the (C (Maybe a) a) instance, we get
      [G] C a b, and hence by superclasses, [G] G a, [G] L a b
      [W] G (Maybe a)
    Use the instance decl to get
      [W] C a beta
    Generate its superclass
      [W] L a beta.  Now using fundeps, combine with [G] L a b to get
      [W] beta ~ b
    which is what we want.

Note [Danger of adding superclasses during solving]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Here's a serious, but now out-dated example, from #4497:

   class Num (RealOf t) => Normed t
   type family RealOf x

Assume the generated wanted constraint is:
   [W] RealOf e ~ e
   [W] Normed e

If we were to be adding the superclasses during simplification we'd get:
   [W] RealOf e ~ e
   [W] Normed e
   [W] RealOf e ~ fuv
   [W] Num fuv
==>
   e := fuv, Num fuv, Normed fuv, RealOf fuv ~ fuv

While looks exactly like our original constraint. If we add the
superclass of (Normed fuv) again we'd loop.  By adding superclasses
definitely only once, during canonicalisation, this situation can't
happen.

Note [Nested quantified constraint superclasses]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider (typecheck/should_compile/T17202)

  class C1 a
  class (forall c. C1 c) => C2 a
  class (forall b. (b ~ F a) => C2 a) => C3 a

Elsewhere in the code, we get a [G] g1 :: C3 a. We expand its superclass
to get [G] g2 :: (forall b. (b ~ F a) => C2 a). This constraint has a
superclass, as well. But we now must be careful: we cannot just add
(forall c. C1 c) as a Given, because we need to remember g2's context.
That new constraint is Given only when forall b. (b ~ F a) is true.

It's tempting to make the new Given be (forall b. (b ~ F a) => forall c. C1 c),
but that's problematic, because it's nested, and ForAllPred is not capable
of representing a nested quantified constraint. (We could change ForAllPred
to allow this, but the solution in this Note is much more local and simpler.)

So, we swizzle it around to get (forall b c. (b ~ F a) => C1 c).

More generally, if we are expanding the superclasses of
  g0 :: forall tvs. theta => cls tys
and find a superclass constraint
  forall sc_tvs. sc_theta => sc_inner_pred
we must have a selector
  sel_id :: forall cls_tvs. cls cls_tvs -> forall sc_tvs. sc_theta => sc_inner_pred
and thus build
  g_sc :: forall tvs sc_tvs. theta => sc_theta => sc_inner_pred
  g_sc = /\ tvs. /\ sc_tvs. \ theta_ids. \ sc_theta_ids.
         sel_id tys (g0 tvs theta_ids) sc_tvs sc_theta_ids

Actually, we cheat a bit by eta-reducing: note that sc_theta_ids are both the
last bound variables and the last arguments. This avoids the need to produce
the sc_theta_ids at all. So our final construction is

  g_sc = /\ tvs. /\ sc_tvs. \ theta_ids.
         sel_id tys (g0 tvs theta_ids) sc_tvs

  -}

makeSuperClasses :: [Ct] -> TcS [Ct]
-- Returns strict superclasses, transitively, see Note [The superclass story]
-- See Note [The superclass story]
-- The loop-breaking here follows Note [Expanding superclasses] in GHC.Tc.Utils.TcType
-- Specifically, for an incoming (C t) constraint, we return all of (C t)'s
--    superclasses, up to /and including/ the first repetition of C
--
-- Example:  class D a => C a
--           class C [a] => D a
-- makeSuperClasses (C x) will return (D x, C [x])
--
-- NB: the incoming constraints have had their cc_pend_sc flag already
--     flipped to False, by isPendingScDict, so we are /obliged/ to at
--     least produce the immediate superclasses
makeSuperClasses cts = concatMapM go cts
  where
    go (CDictCan { cc_ev = ev, cc_class = cls, cc_tyargs = tys })
      = mkStrictSuperClasses ev [] [] cls tys
    go (CQuantCan (QCI { qci_pred = pred, qci_ev = ev }))
      = assertPpr (isClassPred pred) (ppr pred) $  -- The cts should all have
                                                   -- class pred heads
        mkStrictSuperClasses ev tvs theta cls tys
      where
        (tvs, theta, cls, tys) = tcSplitDFunTy (ctEvPred ev)
    go ct = pprPanic "makeSuperClasses" (ppr ct)

mkStrictSuperClasses
    :: CtEvidence
    -> [TyVar] -> ThetaType  -- These two args are non-empty only when taking
                             -- superclasses of a /quantified/ constraint
    -> Class -> [Type] -> TcS [Ct]
-- Return constraints for the strict superclasses of
--   ev :: forall as. theta => cls tys
mkStrictSuperClasses ev tvs theta cls tys
  = mk_strict_superclasses (unitNameSet (className cls))
                           ev tvs theta cls tys

mk_strict_superclasses :: NameSet -> CtEvidence
                       -> [TyVar] -> ThetaType
                       -> Class -> [Type] -> TcS [Ct]
-- Always return the immediate superclasses of (cls tys);
-- and expand their superclasses, provided none of them are in rec_clss
-- nor are repeated
mk_strict_superclasses rec_clss (CtGiven { ctev_evar = evar, ctev_loc = loc })
                       tvs theta cls tys
  = concatMapM do_one_given $
    classSCSelIds cls
  where
    dict_ids  = mkTemplateLocals theta
    this_size = pSizeClassPred cls tys

    do_one_given sel_id
      | isUnliftedType sc_pred
         -- NB: class superclasses are never representation-polymorphic,
         -- so isUnliftedType is OK here.
      , not (null tvs && null theta)
      = -- See Note [Equality superclasses in quantified constraints]
        return []
      | otherwise
      = do { given_ev <- newGivenEvVar sc_loc $
                         mk_given_desc sel_id sc_pred
           ; mk_superclasses rec_clss given_ev tvs theta sc_pred }
      where
        sc_pred = classMethodInstTy sel_id tys

      -- See Note [Nested quantified constraint superclasses]
    mk_given_desc :: Id -> PredType -> (PredType, EvTerm)
    mk_given_desc sel_id sc_pred
      = (swizzled_pred, swizzled_evterm)
      where
        (sc_tvs, sc_rho)          = splitForAllTyCoVars sc_pred
        (sc_theta, sc_inner_pred) = splitFunTys sc_rho

        all_tvs       = tvs `chkAppend` sc_tvs
        all_theta     = theta `chkAppend` (map scaledThing sc_theta)
        swizzled_pred = mkInfSigmaTy all_tvs all_theta sc_inner_pred

        -- evar :: forall tvs. theta => cls tys
        -- sel_id :: forall cls_tvs. cls cls_tvs
        --                        -> forall sc_tvs. sc_theta => sc_inner_pred
        -- swizzled_evterm :: forall tvs sc_tvs. theta => sc_theta => sc_inner_pred
        swizzled_evterm = EvExpr $
          mkLams all_tvs $
          mkLams dict_ids $
          Var sel_id
            `mkTyApps` tys
            `App` (evId evar `mkVarApps` (tvs ++ dict_ids))
            `mkVarApps` sc_tvs

    sc_loc | isCTupleClass cls
           = loc   -- For tuple predicates, just take them apart, without
                   -- adding their (large) size into the chain.  When we
                   -- get down to a base predicate, we'll include its size.
                   -- #10335

           |  isEqPredClass cls || cls `hasKey` coercibleTyConKey
           = loc   -- The only superclasses of ~, ~~, and Coercible are primitive
                   -- equalities, and they don't use the GivenSCOrigin mechanism
                   -- detailed in Note [Solving superclass constraints] in
                   -- GHC.Tc.TyCl.Instance. Skip for a tiny performance win.

           | otherwise
           = loc { ctl_origin = mk_sc_origin (ctLocOrigin loc) }

    -- See Note [Solving superclass constraints] in GHC.Tc.TyCl.Instance
    -- for explanation of GivenSCOrigin and Note [Replacement vs keeping] in
    -- GHC.Tc.Solver.Interact for why we need depths
    mk_sc_origin :: CtOrigin -> CtOrigin
    mk_sc_origin (GivenSCOrigin skol_info sc_depth already_blocked)
      = GivenSCOrigin skol_info (sc_depth + 1)
                      (already_blocked || newly_blocked skol_info)

    mk_sc_origin (GivenOrigin skol_info)
      = -- These cases do not already have a superclass constraint: depth starts at 1
        GivenSCOrigin skol_info 1 (newly_blocked skol_info)

    mk_sc_origin other_orig = pprPanic "Given constraint without given origin" $
                              ppr evar $$ ppr other_orig

    newly_blocked (InstSkol _ head_size) = isJust (this_size `ltPatersonSize` head_size)
    newly_blocked _                      = False

mk_strict_superclasses rec_clss ev tvs theta cls tys
  | all noFreeVarsOfType tys
  = return [] -- Wanteds with no variables yield no superclass constraints.
              -- See Note [Improvement from Ground Wanteds]

  | otherwise -- Wanted case, just add Wanted superclasses
              -- that can lead to improvement.
  = assertPpr (null tvs && null theta) (ppr tvs $$ ppr theta) $
    concatMapM do_one (immSuperClasses cls tys)
  where
    loc = ctEvLoc ev `updateCtLocOrigin` WantedSuperclassOrigin (ctEvPred ev)

    do_one sc_pred
      = do { traceTcS "mk_strict_superclasses Wanted" (ppr (mkClassPred cls tys) $$ ppr sc_pred)
           ; sc_ev <- newWantedNC loc (ctEvRewriters ev) sc_pred
           ; mk_superclasses rec_clss sc_ev [] [] sc_pred }

{- Note [Improvement from Ground Wanteds]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Suppose class C b a => D a b
and consider
  [W] D Int Bool
Is there any point in emitting [W] C Bool Int?  No!  The only point of
emitting superclass constraints for W constraints is to get
improvement, extra unifications that result from functional
dependencies.  See Note [Why adding superclasses can help] above.

But no variables means no improvement; case closed.
-}

mk_superclasses :: NameSet -> CtEvidence
                -> [TyVar] -> ThetaType -> PredType -> TcS [Ct]
-- Return this constraint, plus its superclasses, if any
mk_superclasses rec_clss ev tvs theta pred
  | ClassPred cls tys <- classifyPredType pred
  = mk_superclasses_of rec_clss ev tvs theta cls tys

  | otherwise   -- Superclass is not a class predicate
  = return [mkNonCanonical ev]

mk_superclasses_of :: NameSet -> CtEvidence
                   -> [TyVar] -> ThetaType -> Class -> [Type]
                   -> TcS [Ct]
-- Always return this class constraint,
-- and expand its superclasses
mk_superclasses_of rec_clss ev tvs theta cls tys
  | loop_found = do { traceTcS "mk_superclasses_of: loop" (ppr cls <+> ppr tys)
                    ; return [this_ct] }  -- cc_pend_sc of this_ct = True
  | otherwise  = do { traceTcS "mk_superclasses_of" (vcat [ ppr cls <+> ppr tys
                                                          , ppr (isCTupleClass cls)
                                                          , ppr rec_clss
                                                          ])
                    ; sc_cts <- mk_strict_superclasses rec_clss' ev tvs theta cls tys
                    ; return (this_ct : sc_cts) }
                                   -- cc_pend_sc of this_ct = False
  where
    cls_nm     = className cls
    loop_found = not (isCTupleClass cls) && cls_nm `elemNameSet` rec_clss
                 -- Tuples never contribute to recursion, and can be nested
    rec_clss'  = rec_clss `extendNameSet` cls_nm

    this_ct | null tvs, null theta
            = CDictCan { cc_ev = ev, cc_class = cls, cc_tyargs = tys
                       , cc_pend_sc = loop_found }
                 -- NB: If there is a loop, we cut off, so we have not
                 --     added the superclasses, hence cc_pend_sc = True
            | otherwise
            = CQuantCan (QCI { qci_tvs = tvs, qci_pred = mkClassPred cls tys
                             , qci_ev = ev
                             , qci_pend_sc = loop_found })


{- Note [Equality superclasses in quantified constraints]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider (#15359, #15593, #15625)
  f :: (forall a. theta => a ~ b) => stuff

It's a bit odd to have a local, quantified constraint for `(a~b)`,
but some people want such a thing (see the tickets). And for
Coercible it is definitely useful
  f :: forall m. (forall p q. Coercible p q => Coercible (m p) (m q)))
                 => stuff

Moreover it's not hard to arrange; we just need to look up /equality/
constraints in the quantified-constraint environment, which we do in
GHC.Tc.Solver.Interact.doTopReactOther.

There is a wrinkle though, in the case where 'theta' is empty, so
we have
  f :: (forall a. a~b) => stuff

Now, potentially, the superclass machinery kicks in, in
makeSuperClasses, giving us a a second quantified constraint
       (forall a. a ~# b)
BUT this is an unboxed value!  And nothing has prepared us for
dictionary "functions" that are unboxed.  Actually it does just
about work, but the simplifier ends up with stuff like
   case (/\a. eq_sel d) of df -> ...(df @Int)...
and fails to simplify that any further.  And it doesn't satisfy
isPredTy any more.

So for now we simply decline to take superclasses in the quantified
case.  Instead we have a special case in GHC.Tc.Solver.Interact.doTopReactOther,
which looks for primitive equalities specially in the quantified
constraints.

See also Note [Evidence for quantified constraints] in GHC.Core.Predicate.


************************************************************************
*                                                                      *
*                      Irreducibles canonicalization
*                                                                      *
************************************************************************
-}

canIrred :: CtEvidence -> TcS (StopOrContinue Ct)
-- Precondition: ty not a tuple and no other evidence form
canIrred ev
  = do { let pred = ctEvPred ev
       ; traceTcS "can_pred" (text "IrredPred = " <+> ppr pred)
       ; (redn, rewriters) <- rewrite ev pred
       ; rewriteEvidence rewriters ev redn `andWhenContinue` \ new_ev ->

    do { -- Re-classify, in case rewriting has improved its shape
         -- Code is like the canNC, except
         -- that the IrredPred branch stops work
       ; case classifyPredType (ctEvPred new_ev) of
           ClassPred cls tys     -> canClassNC new_ev cls tys
           EqPred eq_rel ty1 ty2 -> -- IrredPreds have kind Constraint, so
                                    -- cannot become EqPreds
                                    pprPanic "canIrred: EqPred"
                                      (ppr ev $$ ppr eq_rel $$ ppr ty1 $$ ppr ty2)
           ForAllPred tvs th p   -> -- this is highly suspect; Quick Look
                                    -- should never leave a meta-var filled
                                    -- in with a polytype. This is #18987.
                                    do traceTcS "canEvNC:forall" (ppr pred)
                                       canForAllNC ev tvs th p
           IrredPred {}          -> continueWith $
                                    mkIrredCt IrredShapeReason new_ev } }

{- *********************************************************************
*                                                                      *
*                      Quantified predicates
*                                                                      *
********************************************************************* -}

{- Note [Quantified constraints]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The -XQuantifiedConstraints extension allows type-class contexts like this:

  data Rose f x = Rose x (f (Rose f x))

  instance (Eq a, forall b. Eq b => Eq (f b))
        => Eq (Rose f a)  where
    (Rose x1 rs1) == (Rose x2 rs2) = x1==x2 && rs1 == rs2

Note the (forall b. Eq b => Eq (f b)) in the instance contexts.
This quantified constraint is needed to solve the
 [W] (Eq (f (Rose f x)))
constraint which arises form the (==) definition.

The wiki page is
  https://gitlab.haskell.org/ghc/ghc/wikis/quantified-constraints
which in turn contains a link to the GHC Proposal where the change
is specified, and a Haskell Symposium paper about it.

We implement two main extensions to the design in the paper:

 1. We allow a variable in the instance head, e.g.
      f :: forall m a. (forall b. m b) => D (m a)
    Notice the 'm' in the head of the quantified constraint, not
    a class.

 2. We support superclasses to quantified constraints.
    For example (contrived):
      f :: (Ord b, forall b. Ord b => Ord (m b)) => m a -> m a -> Bool
      f x y = x==y
    Here we need (Eq (m a)); but the quantified constraint deals only
    with Ord.  But we can make it work by using its superclass.

Here are the moving parts
  * Language extension {-# LANGUAGE QuantifiedConstraints #-}
    and add it to ghc-boot-th:GHC.LanguageExtensions.Type.Extension

  * A new form of evidence, EvDFun, that is used to discharge
    such wanted constraints

  * checkValidType gets some changes to accept forall-constraints
    only in the right places.

  * Predicate.Pred gets a new constructor ForAllPred, and
    and classifyPredType analyses a PredType to decompose
    the new forall-constraints

  * GHC.Tc.Solver.Monad.InertCans gets an extra field, inert_insts,
    which holds all the Given forall-constraints.  In effect,
    such Given constraints are like local instance decls.

  * When trying to solve a class constraint, via
    GHC.Tc.Solver.Interact.matchInstEnv, use the InstEnv from inert_insts
    so that we include the local Given forall-constraints
    in the lookup.  (See GHC.Tc.Solver.Monad.getInstEnvs.)

  * GHC.Tc.Solver.Canonical.canForAll deals with solving a
    forall-constraint.  See
       Note [Solving a Wanted forall-constraint]

  * We augment the kick-out code to kick out an inert
    forall constraint if it can be rewritten by a new
    type equality; see GHC.Tc.Solver.Monad.kick_out_rewritable

Note that a quantified constraint is never /inferred/
(by GHC.Tc.Solver.simplifyInfer).  A function can only have a
quantified constraint in its type if it is given an explicit
type signature.

-}

canForAllNC :: CtEvidence -> [TyVar] -> TcThetaType -> TcPredType
            -> TcS (StopOrContinue Ct)
canForAllNC ev tvs theta pred
  | isGiven ev  -- See Note [Eagerly expand given superclasses]
  , Just (cls, tys) <- cls_pred_tys_maybe
  = do { sc_cts <- mkStrictSuperClasses ev tvs theta cls tys
       ; emitWork sc_cts
       ; canForAll ev False }

  | otherwise
  = canForAll ev (isJust cls_pred_tys_maybe)

  where
    cls_pred_tys_maybe = getClassPredTys_maybe pred

canForAll :: CtEvidence -> Bool -> TcS (StopOrContinue Ct)
-- We have a constraint (forall as. blah => C tys)
canForAll ev pend_sc
  = do { -- First rewrite it to apply the current substitution
         let pred = ctEvPred ev
       ; (redn, rewriters) <- rewrite ev pred
       ; rewriteEvidence rewriters ev redn `andWhenContinue` \ new_ev ->

    do { -- Now decompose into its pieces and solve it
         -- (It takes a lot less code to rewrite before decomposing.)
       ; case classifyPredType (ctEvPred new_ev) of
           ForAllPred tvs theta pred
              -> solveForAll new_ev tvs theta pred pend_sc
           _  -> pprPanic "canForAll" (ppr new_ev)
    } }

solveForAll :: CtEvidence -> [TyVar] -> TcThetaType -> PredType -> Bool
            -> TcS (StopOrContinue Ct)
solveForAll ev@(CtWanted { ctev_dest = dest, ctev_rewriters = rewriters, ctev_loc = loc })
            tvs theta pred _pend_sc
  = -- See Note [Solving a Wanted forall-constraint]
    setLclEnv (ctLocEnv loc) $
    -- This setLclEnv is important: the emitImplicationTcS uses that
    -- TcLclEnv for the implication, and that in turn sets the location
    -- for the Givens when solving the constraint (#21006)
    do { let empty_subst = mkEmptySubst $ mkInScopeSet $
                           tyCoVarsOfTypes (pred:theta) `delVarSetList` tvs
             is_qc = IsQC (ctLocOrigin loc)

         -- rec {..}: see Note [Keeping SkolemInfo inside a SkolemTv]
         --           in GHC.Tc.Utils.TcType
         -- Very like the code in tcSkolDFunType
       ; rec { skol_info <- mkSkolemInfo skol_info_anon
             ; (subst, skol_tvs) <- tcInstSkolTyVarsX skol_info empty_subst tvs
             ; let inst_pred  = substTy    subst pred
                   inst_theta = substTheta subst theta
                   skol_info_anon = InstSkol is_qc (get_size inst_pred) }

       ; given_ev_vars <- mapM newEvVar inst_theta
       ; (lvl, (w_id, wanteds))
             <- pushLevelNoWorkList (ppr skol_info) $
                do { let loc' = setCtLocOrigin loc (ScOrigin is_qc NakedSc)
                         -- Set the thing to prove to have a ScOrigin, so we are
                         -- careful about its termination checks.
                         -- See (QC-INV) in Note [Solving a Wanted forall-constraint]
                   ; wanted_ev <- newWantedEvVarNC loc' rewriters inst_pred
                   ; return ( ctEvEvId wanted_ev
                            , unitBag (mkNonCanonical wanted_ev)) }

      ; ev_binds <- emitImplicationTcS lvl (getSkolemInfo skol_info) skol_tvs
                                       given_ev_vars wanteds

      ; setWantedEvTerm dest $
        EvFun { et_tvs = skol_tvs, et_given = given_ev_vars
              , et_binds = ev_binds, et_body = w_id }

      ; stopWith ev "Wanted forall-constraint" }
  where
    -- Getting the size of the head is a bit horrible
    -- because of the special treament for class predicates
    get_size pred = case classifyPredType pred of
                      ClassPred cls tys -> pSizeClassPred cls tys
                      _                 -> pSizeType pred

 -- See Note [Solving a Given forall-constraint]
solveForAll ev@(CtGiven {}) tvs _theta pred pend_sc
  = do { addInertForAll qci
       ; stopWith ev "Given forall-constraint" }
  where
    qci = QCI { qci_ev = ev, qci_tvs = tvs
              , qci_pred = pred, qci_pend_sc = pend_sc }

{- Note [Solving a Wanted forall-constraint]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Solving a wanted forall (quantified) constraint
  [W] df :: forall ab. (Eq a, Ord b) => C x a b
is delightfully easy.   Just build an implication constraint
    forall ab. (g1::Eq a, g2::Ord b) => [W] d :: C x a
and discharge df thus:
    df = /\ab. \g1 g2. let <binds> in d
where <binds> is filled in by solving the implication constraint.
All the machinery is to hand; there is little to do.

The tricky point is about termination: see #19690.  We want to maintain
the invariant (QC-INV):

  (QC-INV) Every quantified constraint returns a non-bottom dictionary

just as every top-level instance declaration guarantees to return a non-bottom
dictionary.  But as #19690 shows, it is possible to get a bottom dicionary
by superclass selection if we aren't careful.  The situation is very similar
to that described in Note [Recursive superclasses] in GHC.Tc.TyCl.Instance;
and we use the same solution:

* Give the Givens a CtOrigin of (GivenOrigin (InstSkol IsQC head_size))
* Give the Wanted a CtOrigin of (ScOrigin IsQC NakedSc)

Both of these things are done in solveForAll.  Now the mechanism described
in Note [Solving superclass constraints] in GHC.Tc.TyCl.Instance takes over.

Note [Solving a Given forall-constraint]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
For a Given constraint
  [G] df :: forall ab. (Eq a, Ord b) => C x a b
we just add it to TcS's local InstEnv of known instances,
via addInertForall.  Then, if we look up (C x Int Bool), say,
we'll find a match in the InstEnv.

************************************************************************
*                                                                      *
*        Equalities
*                                                                      *
************************************************************************

Note [Canonicalising equalities]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
In order to canonicalise an equality, we look at the structure of the
two types at hand, looking for similarities. A difficulty is that the
types may look dissimilar before rewriting but similar after rewriting.
However, we don't just want to jump in and rewrite right away, because
this might be wasted effort. So, after looking for similarities and failing,
we rewrite and then try again. Of course, we don't want to loop, so we
track whether or not we've already rewritten.

It is conceivable to do a better job at tracking whether or not a type
is rewritten, but this is left as future work. (Mar '15)

Note [Decomposing FunTy]
~~~~~~~~~~~~~~~~~~~~~~~~
can_eq_nc' may attempt to decompose a FunTy that is un-zonked.  This
means that we may very well have a FunTy containing a type of some
unknown kind. For instance, we may have,

    FunTy (a :: k) Int

Where k is a unification variable. So the calls to splitRuntimeRep_maybe may
fail (returning Nothing).  In that case we'll fall through, zonk, and try again.
Zonking should fill the variable k, meaning that decomposition will succeed the
second time around.

Also note that we require the FunTyFlag to match.  This will stop
us decomposing
   (Int -> Bool)  ~  (Show a => blah)
It's as if we treat (->) and (=>) as different type constructors, which
indeed they are!
-}

canEqNC :: CtEvidence -> EqRel -> Type -> Type -> TcS (StopOrContinue Ct)
canEqNC ev eq_rel ty1 ty2
  = do { result <- zonk_eq_types ty1 ty2
       ; case result of
           Right ty              -> canEqReflexive ev eq_rel ty
           Left (Pair ty1' ty2') -> can_eq_nc False ev' eq_rel ty1' ty1' ty2' ty2'
             where
               ev' | debugIsOn = setCtEvPredType ev $
                                 mkPrimEqPredRole (eqRelRole eq_rel) ty1' ty2'
                   | otherwise = ev
                   -- ev': satisfy the precondition of can_eq_nc
       }

can_eq_nc
   :: Bool            -- True => both types are rewritten
   -> CtEvidence
   -> EqRel
   -> Type -> Type    -- LHS, after and before type-synonym expansion, resp
   -> Type -> Type    -- RHS, after and before type-synonym expansion, resp
   -> TcS (StopOrContinue Ct)
-- Precondition: in DEBUG mode, the `ctev_pred` of `ev` is (ps_ty1 ~# ps_ty2),
--               without zonking
-- This precondition is needed (only in DEBUG) to satisfy the assertions
--   in mkSelCo, called in canDecomposableTyConAppOK and canDecomposableFunTy

can_eq_nc rewritten ev eq_rel ty1 ps_ty1 ty2 ps_ty2
  = do { traceTcS "can_eq_nc" $
         vcat [ ppr rewritten, ppr ev, ppr eq_rel, ppr ty1, ppr ps_ty1, ppr ty2, ppr ps_ty2 ]
       ; rdr_env <- getGlobalRdrEnvTcS
       ; fam_insts <- getFamInstEnvs
       ; can_eq_nc' rewritten rdr_env fam_insts ev eq_rel ty1 ps_ty1 ty2 ps_ty2 }

can_eq_nc'
   :: Bool           -- True => both input types are rewritten
   -> GlobalRdrEnv   -- needed to see which newtypes are in scope
   -> FamInstEnvs    -- needed to unwrap data instances
   -> CtEvidence
   -> EqRel
   -> Type -> Type    -- LHS, after and before type-synonym expansion, resp
   -> Type -> Type    -- RHS, after and before type-synonym expansion, resp
   -> TcS (StopOrContinue Ct)

-- See Note [Comparing nullary type synonyms] in GHC.Core.Type.
can_eq_nc' _flat _rdr_env _envs ev eq_rel ty1@(TyConApp tc1 []) _ps_ty1 (TyConApp tc2 []) _ps_ty2
  | tc1 == tc2
  = canEqReflexive ev eq_rel ty1

-- Expand synonyms first; see Note [Type synonyms and canonicalization]
can_eq_nc' rewritten rdr_env envs ev eq_rel ty1 ps_ty1 ty2 ps_ty2
  | Just ty1' <- coreView ty1 = can_eq_nc' rewritten rdr_env envs ev eq_rel ty1' ps_ty1 ty2  ps_ty2
  | Just ty2' <- coreView ty2 = can_eq_nc' rewritten rdr_env envs ev eq_rel ty1  ps_ty1 ty2' ps_ty2

-- need to check for reflexivity in the ReprEq case.
-- See Note [Eager reflexivity check]
-- Check only when rewritten because the zonk_eq_types check in canEqNC takes
-- care of the non-rewritten case.
can_eq_nc' True _rdr_env _envs ev ReprEq ty1 _ ty2 _
  | ty1 `tcEqType` ty2
  = canEqReflexive ev ReprEq ty1

-- When working with ReprEq, unwrap newtypes.
-- See Note [Unwrap newtypes first]
-- This must be above the TyVarTy case, in order to guarantee (TyEq:N)
can_eq_nc' _rewritten rdr_env envs ev eq_rel ty1 ps_ty1 ty2 ps_ty2
  | ReprEq <- eq_rel
  , Just stuff1 <- tcTopNormaliseNewTypeTF_maybe envs rdr_env ty1
  = can_eq_newtype_nc ev NotSwapped ty1 stuff1 ty2 ps_ty2

  | ReprEq <- eq_rel
  , Just stuff2 <- tcTopNormaliseNewTypeTF_maybe envs rdr_env ty2
  = can_eq_newtype_nc ev IsSwapped ty2 stuff2 ty1 ps_ty1

-- Then, get rid of casts
can_eq_nc' rewritten _rdr_env _envs ev eq_rel (CastTy ty1 co1) _ ty2 ps_ty2
  | isNothing (canEqLHS_maybe ty2)  -- See (3) in Note [Equalities with incompatible kinds]
  = canEqCast rewritten ev eq_rel NotSwapped ty1 co1 ty2 ps_ty2
can_eq_nc' rewritten _rdr_env _envs ev eq_rel ty1 ps_ty1 (CastTy ty2 co2) _
  | isNothing (canEqLHS_maybe ty1)  -- See (3) in Note [Equalities with incompatible kinds]
  = canEqCast rewritten ev eq_rel IsSwapped ty2 co2 ty1 ps_ty1

----------------------
-- Otherwise try to decompose
----------------------

-- Literals
can_eq_nc' _rewritten _rdr_env _envs ev eq_rel ty1@(LitTy l1) _ (LitTy l2) _
 | l1 == l2
  = do { setEvBindIfWanted ev (evCoercion $ mkReflCo (eqRelRole eq_rel) ty1)
       ; stopWith ev "Equal LitTy" }

-- Decompose FunTy: (s -> t) and (c => t)
-- NB: don't decompose (Int -> blah) ~ (Show a => blah)
can_eq_nc' _rewritten _rdr_env _envs ev eq_rel
           (FunTy { ft_mult = am1, ft_af = af1, ft_arg = ty1a, ft_res = ty1b }) _ps_ty1
           (FunTy { ft_mult = am2, ft_af = af2, ft_arg = ty2a, ft_res = ty2b }) _ps_ty2
  | af1 == af2  -- See Note [Decomposing FunTy]
  = canDecomposableFunTy ev eq_rel af1 (am1,ty1a,ty1b) (am2,ty2a,ty2b)

-- Decompose type constructor applications
-- NB: we have expanded type synonyms already
can_eq_nc' _rewritten _rdr_env _envs ev eq_rel ty1 _ ty2 _
  | Just (tc1, tys1) <- tcSplitTyConApp_maybe ty1
  , Just (tc2, tys2) <- tcSplitTyConApp_maybe ty2
   -- we want to catch e.g. Maybe Int ~ (Int -> Int) here for better
   -- error messages rather than decomposing into AppTys;
   -- hence no direct match on TyConApp
  , not (isTypeFamilyTyCon tc1)
  , not (isTypeFamilyTyCon tc2)
  = canTyConApp ev eq_rel tc1 tys1 tc2 tys2

can_eq_nc' _rewritten _rdr_env _envs ev eq_rel
           s1@(ForAllTy (Bndr _ vis1) _) _
           s2@(ForAllTy (Bndr _ vis2) _) _
  | vis1 `eqForAllVis` vis2 -- Note [ForAllTy and type equality]
  = can_eq_nc_forall ev eq_rel s1 s2

-- See Note [Canonicalising type applications] about why we require rewritten types
-- Use tcSplitAppTy, not matching on AppTy, to catch oversaturated type families
-- NB: Only decompose AppTy for nominal equality.
--     See Note [Decomposing AppTy equalities]
can_eq_nc' True _rdr_env _envs ev NomEq ty1 _ ty2 _
  | Just (t1, s1) <- tcSplitAppTy_maybe ty1
  , Just (t2, s2) <- tcSplitAppTy_maybe ty2
  = can_eq_app ev t1 s1 t2 s2

-------------------
-- Can't decompose.
-------------------

-- No similarity in type structure detected. Rewrite and try again.
can_eq_nc' False rdr_env envs ev eq_rel _ ps_ty1 _ ps_ty2
  = -- Rewrite the two types and try again
    do { (redn1@(Reduction _ xi1), rewriters1) <- rewrite ev ps_ty1
       ; (redn2@(Reduction _ xi2), rewriters2) <- rewrite ev ps_ty2
       ; new_ev <- rewriteEqEvidence (rewriters1 S.<> rewriters2) ev NotSwapped redn1 redn2
       ; can_eq_nc' True rdr_env envs new_ev eq_rel xi1 xi1 xi2 xi2 }

----------------------------
-- Look for a canonical LHS. See Note [Canonical LHS].
-- Only rewritten types end up below here.
----------------------------

-- NB: pattern match on True: we want only rewritten types sent to canEqLHS
-- This means we've rewritten any variables and reduced any type family redexes
-- See also Note [No top-level newtypes on RHS of representational equalities]
can_eq_nc' True _rdr_env _envs ev eq_rel ty1 ps_ty1 ty2 ps_ty2
  | Just can_eq_lhs1 <- canEqLHS_maybe ty1
  = canEqCanLHS ev eq_rel NotSwapped can_eq_lhs1 ps_ty1 ty2 ps_ty2

  | Just can_eq_lhs2 <- canEqLHS_maybe ty2
  = canEqCanLHS ev eq_rel IsSwapped can_eq_lhs2 ps_ty2 ty1 ps_ty1

     -- If the type is TyConApp tc1 args1, then args1 really can't be less
     -- than tyConArity tc1. It could be *more* than tyConArity, but then we
     -- should have handled the case as an AppTy. That case only fires if
     -- _both_ sides of the equality are AppTy-like... but if one side is
     -- AppTy-like and the other isn't (and it also isn't a variable or
     -- saturated type family application, both of which are handled by
     -- can_eq_nc'), we're in a failure mode and can just fall through.

----------------------------
-- Fall-through. Give up.
----------------------------

-- We've rewritten and the types don't match. Give up.
can_eq_nc' True _rdr_env _envs ev eq_rel _ ps_ty1 _ ps_ty2
  = do { traceTcS "can_eq_nc' catch-all case" (ppr ps_ty1 $$ ppr ps_ty2)
       ; case eq_rel of -- See Note [Unsolved equalities]
            ReprEq -> continueWith (mkIrredCt ReprEqReason ev)
            NomEq  -> continueWith (mkIrredCt ShapeMismatchReason ev) }
          -- No need to call canEqFailure/canEqHardFailure because they
          -- rewrite, and the types involved here are already rewritten


{- Note [Unsolved equalities]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If we have an unsolved equality like
  (a b ~R# Int)
that is not necessarily insoluble!  Maybe 'a' will turn out to be a newtype.
So we want to make it a potentially-soluble Irred not an insoluble one.
Missing this point is what caused #15431
-}

---------------------------------
can_eq_nc_forall :: CtEvidence -> EqRel
                 -> Type -> Type    -- LHS and RHS
                 -> TcS (StopOrContinue Ct)
-- (forall as. phi1) ~ (forall bs. phi2)
-- Check for length match of as, bs
-- Then build an implication constraint: forall as. phi1 ~ phi2[as/bs]
-- But remember also to unify the kinds of as and bs
--  (this is the 'go' loop), and actually substitute phi2[as |> cos / bs]
-- Remember also that we might have forall z (a:z). blah
--  so we must proceed one binder at a time (#13879)

can_eq_nc_forall ev eq_rel s1 s2
 | CtWanted { ctev_loc = loc, ctev_dest = orig_dest, ctev_rewriters = rewriters } <- ev
 = do { let free_tvs       = tyCoVarsOfTypes [s1,s2]
            (bndrs1, phi1) = tcSplitForAllTyVarBinders s1
            (bndrs2, phi2) = tcSplitForAllTyVarBinders s2
      ; if not (equalLength bndrs1 bndrs2)
        then do { traceTcS "Forall failure" $
                     vcat [ ppr s1, ppr s2, ppr bndrs1, ppr bndrs2
                          , ppr (binderFlags bndrs1)
                          , ppr (binderFlags bndrs2) ]
                ; canEqHardFailure ev s1 s2 }
        else
   do { traceTcS "Creating implication for polytype equality" $ ppr ev
      ; let empty_subst1 = mkEmptySubst $ mkInScopeSet free_tvs
      ; skol_info <- mkSkolemInfo (UnifyForAllSkol phi1)
      ; (subst1, skol_tvs) <- tcInstSkolTyVarsX skol_info empty_subst1 $
                              binderVars bndrs1

      ; let phi1' = substTy subst1 phi1

            -- Unify the kinds, extend the substitution
            go :: [TcTyVar] -> Subst -> [TyVarBinder]
               -> TcS (TcCoercion, Cts)
            go (skol_tv:skol_tvs) subst (bndr2:bndrs2)
              = do { let tv2 = binderVar bndr2
                   ; (kind_co, wanteds1) <- unify loc rewriters Nominal (tyVarKind skol_tv)
                                                  (substTy subst (tyVarKind tv2))
                   ; let subst' = extendTvSubstAndInScope subst tv2
                                       (mkCastTy (mkTyVarTy skol_tv) kind_co)
                         -- skol_tv is already in the in-scope set, but the
                         -- free vars of kind_co are not; hence "...AndInScope"
                   ; (co, wanteds2) <- go skol_tvs subst' bndrs2
                   ; return ( mkForAllCo skol_tv kind_co co
                            , wanteds1 `unionBags` wanteds2 ) }

            -- Done: unify phi1 ~ phi2
            go [] subst bndrs2
              = assert (null bndrs2) $
                unify loc rewriters (eqRelRole eq_rel) phi1' (substTyUnchecked subst phi2)

            go _ _ _ = panic "cna_eq_nc_forall"  -- case (s:ss) []

            empty_subst2 = mkEmptySubst (getSubstInScope subst1)

      ; (lvl, (all_co, wanteds)) <- pushLevelNoWorkList (ppr skol_info) $
                                    go skol_tvs empty_subst2 bndrs2
      ; emitTvImplicationTcS lvl (getSkolemInfo skol_info) skol_tvs wanteds

      ; setWantedEq orig_dest all_co
      ; stopWith ev "Deferred polytype equality" } }

 | otherwise
 = do { traceTcS "Omitting decomposition of given polytype equality" $
        pprEq s1 s2    -- See Note [Do not decompose Given polytype equalities]
      ; stopWith ev "Discard given polytype equality" }

 where
    unify :: CtLoc -> RewriterSet -> Role -> TcType -> TcType -> TcS (TcCoercion, Cts)
    -- This version returns the wanted constraint rather
    -- than putting it in the work list
    unify loc rewriters role ty1 ty2
      | ty1 `tcEqType` ty2
      = return (mkReflCo role ty1, emptyBag)
      | otherwise
      = do { (wanted, co) <- newWantedEq loc rewriters role ty1 ty2
           ; return (co, unitBag (mkNonCanonical wanted)) }

---------------------------------
-- | Compare types for equality, while zonking as necessary. Gives up
-- as soon as it finds that two types are not equal.
-- This is quite handy when some unification has made two
-- types in an inert Wanted to be equal. We can discover the equality without
-- rewriting, which is sometimes very expensive (in the case of type functions).
-- In particular, this function makes a ~20% improvement in test case
-- perf/compiler/T5030.
--
-- Returns either the (partially zonked) types in the case of
-- inequality, or the one type in the case of equality. canEqReflexive is
-- a good next step in the 'Right' case. Returning 'Left' is always safe.
--
-- NB: This does *not* look through type synonyms. In fact, it treats type
-- synonyms as rigid constructors. In the future, it might be convenient
-- to look at only those arguments of type synonyms that actually appear
-- in the synonym RHS. But we're not there yet.
zonk_eq_types :: TcType -> TcType -> TcS (Either (Pair TcType) TcType)
zonk_eq_types = go
  where
    go (TyVarTy tv1) (TyVarTy tv2) = tyvar_tyvar tv1 tv2
    go (TyVarTy tv1) ty2           = tyvar NotSwapped tv1 ty2
    go ty1 (TyVarTy tv2)           = tyvar IsSwapped  tv2 ty1

    -- We handle FunTys explicitly here despite the fact that they could also be
    -- treated as an application. Why? Well, for one it's cheaper to just look
    -- at two types (the argument and result types) than four (the argument,
    -- result, and their RuntimeReps). Also, we haven't completely zonked yet,
    -- so we may run into an unzonked type variable while trying to compute the
    -- RuntimeReps of the argument and result types. This can be observed in
    -- testcase tc269.
    go (FunTy af1 w1 arg1 res1) (FunTy af2 w2 arg2 res2)
      | af1 == af2
      , eqType w1 w2
      = do { res_a <- go arg1 arg2
           ; res_b <- go res1 res2
           ; return $ combine_rev (FunTy af1 w1) res_b res_a }

    go ty1@(FunTy {}) ty2 = bale_out ty1 ty2
    go ty1 ty2@(FunTy {}) = bale_out ty1 ty2

    go ty1 ty2
      | Just (tc1, tys1) <- splitTyConAppNoView_maybe ty1
      , Just (tc2, tys2) <- splitTyConAppNoView_maybe ty2
      = if tc1 == tc2 && tys1 `equalLength` tys2
          -- Crucial to check for equal-length args, because
          -- we cannot assume that the two args to 'go' have
          -- the same kind.  E.g go (Proxy *      (Maybe Int))
          --                        (Proxy (*->*) Maybe)
          -- We'll call (go (Maybe Int) Maybe)
          -- See #13083
        then tycon tc1 tys1 tys2
        else bale_out ty1 ty2

    go ty1 ty2
      | Just (ty1a, ty1b) <- tcSplitAppTyNoView_maybe ty1
      , Just (ty2a, ty2b) <- tcSplitAppTyNoView_maybe ty2
      = do { res_a <- go ty1a ty2a
           ; res_b <- go ty1b ty2b
           ; return $ combine_rev mkAppTy res_b res_a }

    go ty1@(LitTy lit1) (LitTy lit2)
      | lit1 == lit2
      = return (Right ty1)

    go ty1 ty2 = bale_out ty1 ty2
      -- We don't handle more complex forms here

    bale_out ty1 ty2 = return $ Left (Pair ty1 ty2)

    tyvar :: SwapFlag -> TcTyVar -> TcType
          -> TcS (Either (Pair TcType) TcType)
      -- Try to do as little as possible, as anything we do here is redundant
      -- with rewriting. In particular, no need to zonk kinds. That's why
      -- we don't use the already-defined zonking functions
    tyvar swapped tv ty
      = case tcTyVarDetails tv of
          MetaTv { mtv_ref = ref }
            -> do { cts <- readTcRef ref
                  ; case cts of
                      Flexi        -> give_up
                      Indirect ty' -> do { trace_indirect tv ty'
                                         ; unSwap swapped go ty' ty } }
          _ -> give_up
      where
        give_up = return $ Left $ unSwap swapped Pair (mkTyVarTy tv) ty

    tyvar_tyvar tv1 tv2
      | tv1 == tv2 = return (Right (mkTyVarTy tv1))
      | otherwise  = do { (ty1', progress1) <- quick_zonk tv1
                        ; (ty2', progress2) <- quick_zonk tv2
                        ; if progress1 || progress2
                          then go ty1' ty2'
                          else return $ Left (Pair (TyVarTy tv1) (TyVarTy tv2)) }

    trace_indirect tv ty
       = traceTcS "Following filled tyvar (zonk_eq_types)"
                  (ppr tv <+> equals <+> ppr ty)

    quick_zonk tv = case tcTyVarDetails tv of
      MetaTv { mtv_ref = ref }
        -> do { cts <- readTcRef ref
              ; case cts of
                  Flexi        -> return (TyVarTy tv, False)
                  Indirect ty' -> do { trace_indirect tv ty'
                                     ; return (ty', True) } }
      _ -> return (TyVarTy tv, False)

      -- This happens for type families, too. But recall that failure
      -- here just means to try harder, so it's OK if the type function
      -- isn't injective.
    tycon :: TyCon -> [TcType] -> [TcType]
          -> TcS (Either (Pair TcType) TcType)
    tycon tc tys1 tys2
      = do { results <- zipWithM go tys1 tys2
           ; return $ case combine_results results of
               Left tys  -> Left (mkTyConApp tc <$> tys)
               Right tys -> Right (mkTyConApp tc tys) }

    combine_results :: [Either (Pair TcType) TcType]
                    -> Either (Pair [TcType]) [TcType]
    combine_results = bimap (fmap reverse) reverse .
                      foldl' (combine_rev (:)) (Right [])

      -- combine (in reverse) a new result onto an already-combined result
    combine_rev :: (a -> b -> c)
                -> Either (Pair b) b
                -> Either (Pair a) a
                -> Either (Pair c) c
    combine_rev f (Left list) (Left elt) = Left (f <$> elt     <*> list)
    combine_rev f (Left list) (Right ty) = Left (f <$> pure ty <*> list)
    combine_rev f (Right tys) (Left elt) = Left (f <$> elt     <*> pure tys)
    combine_rev f (Right tys) (Right ty) = Right (f ty tys)

{- Note [Unwrap newtypes first]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
See also Note [Decomposing newtype equalities]

Consider
  newtype N m a = MkN (m a)
N will get a conservative, Nominal role for its second parameter 'a',
because it appears as an argument to the unknown 'm'. Now consider
  [W] N Maybe a  ~R#  N Maybe b

If we /decompose/, we'll get
  [W] a ~N# b

But if instead we /unwrap/ we'll get
  [W] Maybe a ~R# Maybe b
which in turn gives us
  [W] a ~R# b
which is easier to satisfy.

Conclusion: we must unwrap newtypes before decomposing them. This happens
in `can_eq_newtype_nc`

We did flirt with making the /rewriter/ expand newtypes, rather than
doing it in `can_eq_newtype_nc`.   But with recursive newtypes we want
to be super-careful about expanding!

   newtype A = MkA [A]   -- Recursive!

   f :: A -> [A]
   f = coerce

We have [W] A ~R# [A].  If we rewrite [A], it'll expand to
   [[[[[...]]]]]
and blow the reduction stack.  See Note [Newtypes can blow the stack]
in GHC.Tc.Solver.Rewrite.  But if we expand only the /top level/ of
both sides, we get
   [W] [A] ~R# [A]
which we can, just, solve by reflexivity.

So we simply unwrap, on-demand, at top level, in `can_eq_newtype_nc`.

This is all very delicate. There is a real risk of a loop in the type checker
with recursive newtypes -- but I think we're doomed to do *something*
delicate, as we're really trying to solve for equirecursive type
equality. Bottom line for users: recursive newtypes do not play well with type
inference for representational equality.  See also Section 5.3.1 and 5.3.4 of
"Safe Zero-cost Coercions for Haskell" (JFP 2016).

See also Note [Decomposing newtype equalities].

--- Historical side note ---

We flirted with doing /both/ unwrap-at-top-level /and/ rewrite-deeply;
see #22519.  But that didn't work: see discussion in #22924. Specifically
we got a loop with a minor variation:
   f2 :: a -> [A]
   f2 = coerce

Note [Eager reflexivity check]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Suppose we have

  newtype X = MkX (Int -> X)

and

  [W] X ~R X

Naively, we would start unwrapping X and end up in a loop. Instead,
we do this eager reflexivity check. This is necessary only for representational
equality because the rewriter technology deals with the similar case
(recursive type families) for nominal equality.

Note that this check does not catch all cases, but it will catch the cases
we're most worried about, types like X above that are actually inhabited.

Here's another place where this reflexivity check is key:
Consider trying to prove (f a) ~R (f a). The AppTys in there can't
be decomposed, because representational equality isn't congruent with respect
to AppTy. So, when canonicalising the equality above, we get stuck and
would normally produce a CIrredCan. However, we really do want to
be able to solve (f a) ~R (f a). So, in the representational case only,
we do a reflexivity check.

(This would be sound in the nominal case, but unnecessary, and I [Richard
E.] am worried that it would slow down the common case.)

 Note [Newtypes can blow the stack]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Suppose we have

  newtype X = MkX (Int -> X)
  newtype Y = MkY (Int -> Y)

and now wish to prove

  [W] X ~R Y

This Wanted will loop, expanding out the newtypes ever deeper looking
for a solid match or a solid discrepancy. Indeed, there is something
appropriate to this looping, because X and Y *do* have the same representation,
in the limit -- they're both (Fix ((->) Int)). However, no finitely-sized
coercion will ever witness it. This loop won't actually cause GHC to hang,
though, because we check our depth in `can_eq_newtype_nc`.
-}

------------------------
-- | We're able to unwrap a newtype. Update the bits accordingly.
can_eq_newtype_nc :: CtEvidence           -- ^ :: ty1 ~ ty2
                  -> SwapFlag
                  -> TcType                                    -- ^ ty1
                  -> ((Bag GlobalRdrElt, TcCoercion), TcType)  -- ^ :: ty1 ~ ty1'
                  -> TcType               -- ^ ty2
                  -> TcType               -- ^ ty2, with type synonyms
                  -> TcS (StopOrContinue Ct)
can_eq_newtype_nc ev swapped ty1 ((gres, co1), ty1') ty2 ps_ty2
  = do { traceTcS "can_eq_newtype_nc" $
         vcat [ ppr ev, ppr swapped, ppr co1, ppr gres, ppr ty1', ppr ty2 ]

         -- Check for blowing our stack, and increase the depth
         -- See Note [Newtypes can blow the stack]
       ; let loc = ctEvLoc ev
             ev' = ev `setCtEvLoc` bumpCtLocDepth loc
       ; checkReductionDepth loc ty1

         -- Next, we record uses of newtype constructors, since coercing
         -- through newtypes is tantamount to using their constructors.
       ; recordUsedGREs gres

       ; let redn1 = mkReduction co1 ty1'

       ; new_ev <- rewriteEqEvidence emptyRewriterSet ev' swapped
                     redn1
                     (mkReflRedn Representational ps_ty2)
       ; can_eq_nc False new_ev ReprEq ty1' ty1' ty2 ps_ty2 }

---------
-- ^ Decompose a type application.
-- All input types must be rewritten. See Note [Canonicalising type applications]
-- Nominal equality only!
can_eq_app :: CtEvidence       -- :: s1 t1 ~N s2 t2
           -> Xi -> Xi         -- s1 t1
           -> Xi -> Xi         -- s2 t2
           -> TcS (StopOrContinue Ct)

-- AppTys only decompose for nominal equality, so this case just leads
-- to an irreducible constraint; see typecheck/should_compile/T10494
-- See Note [Decomposing AppTy equalities]
can_eq_app ev s1 t1 s2 t2
  | CtWanted { ctev_dest = dest, ctev_rewriters = rewriters } <- ev
  = do { co_s <- unifyWanted rewriters loc Nominal s1 s2
       ; let arg_loc
               | isNextArgVisible s1 = loc
               | otherwise           = updateCtLocOrigin loc toInvisibleOrigin
       ; co_t <- unifyWanted rewriters arg_loc Nominal t1 t2
       ; let co = mkAppCo co_s co_t
       ; setWantedEq dest co
       ; stopWith ev "Decomposed [W] AppTy" }

    -- If there is a ForAll/(->) mismatch, the use of the Left coercion
    -- below is ill-typed, potentially leading to a panic in splitTyConApp
    -- Test case: typecheck/should_run/Typeable1
    -- We could also include this mismatch check above (for W and D), but it's slow
    -- and we'll get a better error message not doing it
  | s1k `mismatches` s2k
  = canEqHardFailure ev (s1 `mkAppTy` t1) (s2 `mkAppTy` t2)

  | CtGiven { ctev_evar = evar } <- ev
  = do { let co   = mkCoVarCo evar
             co_s = mkLRCo CLeft  co
             co_t = mkLRCo CRight co
       ; evar_s <- newGivenEvVar loc ( mkTcEqPredLikeEv ev s1 s2
                                     , evCoercion co_s )
       ; evar_t <- newGivenEvVar loc ( mkTcEqPredLikeEv ev t1 t2
                                     , evCoercion co_t )
       ; emitWorkNC [evar_t]
       ; canEqNC evar_s NomEq s1 s2 }

  where
    loc = ctEvLoc ev

    s1k = typeKind s1
    s2k = typeKind s2

    k1 `mismatches` k2
      =  isForAllTy k1 && not (isForAllTy k2)
      || not (isForAllTy k1) && isForAllTy k2

-----------------------
-- | Break apart an equality over a casted type
-- looking like   (ty1 |> co1) ~ ty2   (modulo a swap-flag)
canEqCast :: Bool         -- are both types rewritten?
          -> CtEvidence
          -> EqRel
          -> SwapFlag
          -> TcType -> Coercion   -- LHS (res. RHS), ty1 |> co1
          -> TcType -> TcType     -- RHS (res. LHS), ty2 both normal and pretty
          -> TcS (StopOrContinue Ct)
canEqCast rewritten ev eq_rel swapped ty1 co1 ty2 ps_ty2
  = do { traceTcS "Decomposing cast" (vcat [ ppr ev
                                           , ppr ty1 <+> text "|>" <+> ppr co1
                                           , ppr ps_ty2 ])
       ; new_ev <- rewriteEqEvidence emptyRewriterSet ev swapped
                      (mkGReflLeftRedn role ty1 co1)
                      (mkReflRedn role ps_ty2)
       ; can_eq_nc rewritten new_ev eq_rel ty1 ty1 ty2 ps_ty2 }
  where
    role = eqRelRole eq_rel

------------------------
canTyConApp :: CtEvidence -> EqRel
            -> TyCon -> [TcType]
            -> TyCon -> [TcType]
            -> TcS (StopOrContinue Ct)
-- See Note [Decomposing TyConApp equalities]
-- See Note [Decomposing Dependent TyCons and Processing Wanted Equalities]
-- Neither tc1 nor tc2 is a saturated funTyCon, nor a type family
-- But they can be data families.
canTyConApp ev eq_rel tc1 tys1 tc2 tys2
  | tc1 == tc2
  , tys1 `equalLength` tys2
  = do { inerts <- getTcSInerts
       ; if can_decompose inerts
         then canDecomposableTyConAppOK ev eq_rel tc1 tys1 tys2
         else canEqFailure ev eq_rel ty1 ty2 }

  -- See Note [Skolem abstract data] in GHC.Core.Tycon
  | tyConSkolem tc1 || tyConSkolem tc2
  = do { traceTcS "canTyConApp: skolem abstract" (ppr tc1 $$ ppr tc2)
       ; continueWith (mkIrredCt AbstractTyConReason ev) }

  -- Fail straight away for better error messages
  -- See Note [Use canEqFailure in canDecomposableTyConApp]
  | eq_rel == ReprEq && not (isGenerativeTyCon tc1 Representational &&
                             isGenerativeTyCon tc2 Representational)
  = canEqFailure ev eq_rel ty1 ty2

  | otherwise
  = canEqHardFailure ev ty1 ty2
  where
    -- Reconstruct the types for error messages. This would do
    -- the wrong thing (from a pretty printing point of view)
    -- for functions, because we've lost the FunTyFlag; but
    -- in fact we never call canTyConApp on a saturated FunTyCon
    ty1 = mkTyConApp tc1 tys1
    ty2 = mkTyConApp tc2 tys2

     -- See Note [Decomposing TyConApp equalities]
     -- and Note [Decomposing newtype equalities]
    can_decompose inerts
      =  isInjectiveTyCon tc1 (eqRelRole eq_rel)
      || (assert (eq_rel == ReprEq) $
          -- assert: isInjectiveTyCon is always True for Nominal except
          --   for type synonyms/families, neither of which happen here
          -- Moreover isInjectiveTyCon is True for Representational
          --   for algebraic data types.  So we are down to newtypes
          --   and data families.
          ctEvFlavour ev == Wanted && noGivenNewtypeReprEqs tc1 inerts)
             -- See Note [Decomposing newtype equalities] (EX2)

{-
Note [Use canEqFailure in canDecomposableTyConApp]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We must use canEqFailure, not canEqHardFailure here, because there is
the possibility of success if working with a representational equality.
Here is one case:

  type family TF a where TF Char = Bool
  data family DF a
  newtype instance DF Bool = MkDF Int

Suppose we are canonicalising (Int ~R DF (TF a)), where we don't yet
know `a`. This is *not* a hard failure, because we might soon learn
that `a` is, in fact, Char, and then the equality succeeds.

Here is another case:

  [G] Age ~R Int

where Age's constructor is not in scope. We don't want to report
an "inaccessible code" error in the context of this Given!

For example, see typecheck/should_compile/T10493, repeated here:

  import Data.Ord (Down)  -- no constructor

  foo :: Coercible (Down Int) Int => Down Int -> Int
  foo = coerce

That should compile, but only because we use canEqFailure and not
canEqHardFailure.

Note [Fast path when decomposing TyConApps]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If we see (T s1 t1 ~ T s2 t2), then we can just decompose to
  (s1 ~ s2, t1 ~ t2)
and push those back into the work list.  But if
  s1 = K k1    s2 = K k2
then we will just decompose s1~s2, and it might be better to
do so on the spot.  An important special case is where s1=s2,
and we get just Refl.

So canDecomposableTyConAppOK uses unifyWanted etc to short-cut that work.
See also Note [Decomposing Dependent TyCons and Processing Wanted Equalities]

Note [Decomposing TyConApp equalities]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Suppose we have
        [G/W] T ty1 ~r T ty2
Can we decompose it, and replace it by
        [G/W] ty1 ~r' ty2
and if so what role is r'?  (In this Note, all the "~" are primitive
equalities "~#", but I have dropped the noisy "#" symbols.)  Lots of
background in the paper "Safe zero-cost coercions for Haskell".

This Note covers the topic for
  * Datatypes
  * Newtypes
  * Data families
For the rest:
  * Type synonyms: are always expanded
  * Type families: see Note [Decomposing type family applications]
  * AppTy:         see Note [Decomposing AppTy equalities].

---- Roles of the decomposed constraints ----
For a start, the role r' will always be defined like this:
  * If r=N then r' = N
  * If r=R then r' = role of T's first argument

For example:
   data TR a = MkTR a       -- Role of T's first arg is Representational
   data TN a = MkTN (F a)   -- Role of T's first arg is Nominal

The function tyConRolesX :: Role -> TyCon -> [Role] gets the argument
role r' for a TyCon T at role r.  E.g.
   tyConRolesX Nominal          TR = [Nominal]
   tyConRolesX Representational TR = [Representational]

---- Soundness and completeness ----
For Givens, for /soundness/ of decomposition we need, forall ty1,ty2:
    T ty1 ~r T ty2   ===>    ty1 ~r' ty2
Here "===>" means "implies".  That is, given evidence for (co1 : T ty1 ~r T co2)
we can produce evidence for (co2 : ty1 ~r' ty2).  But in the solver we
/replace/ co1 with co2 in the inert set, and we don't want to lose any proofs
thereby. So for /completeness/ of decomposition we also need the reverse:
    ty1 ~r' ty2   ===>    T ty1 ~r T ty2

For Wanteds, for /soundness/ of decomposition we need:
    ty1 ~r' ty2   ===>    T ty1 ~r T ty2
because if we do decompose we'll get evidence (co2 : ty1 ~r' ty2) and
from that we want to derive evidence (T co2 : T ty1 ~r T ty2).
For /completeness/ of decomposition we need the reverse implication too,
else we may decompose to a new proof obligation that is stronger than
the one we started with.  See Note [Decomposing newtype equalities].

---- Injectivity ----
When do these bi-implications hold? In one direction it is easy.
We /always/ have
    ty1 ~r'  ty2   ===>    T ty1 ~r T ty2
This is the CO_TYCONAPP rule of the paper (Fig 5); see also the
TyConAppCo case of GHC.Core.Lint.lintCoercion.

In the other direction, we have
    T ty1 ~r T ty2   ==>   ty1 ~r' ty2  if T is /injective at role r/
This is the very /definition/ of injectivity: injectivity means result
is the same => arguments are the same, modulo the role shift.
See comments on GHC.Core.TyCon.isInjectiveTyCon.  This is also
the CO_NTH rule in Fig 5 of the paper, except in the paper only
newtypes are non-injective at representation role, so the rule says "H
is not a newtype".

Injectivity is a bit subtle:
                 Nominal   Representational
   Datatype        YES        YES
   Newtype         YES        NO{1}
   Data family     YES        NO{2}

{1} Consider newtype N a = MkN (F a)   -- Arg has Nominal role
    Is it true that (N t1) ~R (N t2)   ==>   t1 ~N t2  ?
    No, absolutely not.  E.g.
       type instance F Int = Int; type instance F Bool = Char
       Then (N Int) ~R (N Bool), by unwrapping, but we don't want Int~Char!

    See Note [Decomposing newtype equalities]

{2} We must treat data families precisely like newtypes, because of the
    possibility of newtype instances. See also
    Note [Decomposing newtype equalities]. See #10534 and
    test case typecheck/should_fail/T10534.

---- Takeaway summary -----
For sound and complete decomposition, we simply need injectivity;
that is for isInjectiveTyCon to be true:

* At Nominal role, isInjectiveTyCon is True for all the TyCons we are
  considering in this Note: datatypes, newtypes, and data families.

* For Givens, injectivity is necessary for soundness; completeness has no
  side conditions.

* For Wanteds, soundness has no side conditions; but injectivity is needed
  for completeness. See Note [Decomposing newtype equalities]

This is implemented in `can_decompose` in `canTyConApp`; it looks at
injectivity, just as specified above.


Note [Decomposing type family applications]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Supose we have
   [G/W]  (F ty1) ~r  (F ty2)
This is handled by the TyFamLHS/TyFamLHS case of canEqCanLHS2.

We never decompose to
   [G/W]  ty1 ~r' ty2

Instead

* For Givens we do nothing. Injective type families have no corresponding
  evidence of their injectivity, so we cannot decompose an
  injective-type-family Given.

* For Wanteds, for the Nominal role only, we emit new Wanteds rather like
  functional dependencies, for each injective argument position.

  E.g type family F a b   -- injective in first arg, but not second
      [W] (F s1 t1) ~N (F s2 t2)
  Emit new Wanteds
      [W] s1 ~N s2
  But retain the existing, unsolved constraint.

Note [Decomposing newtype equalities]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
This Note also applies to data families, which we treat like
newtype in case of 'newtype instance'.

As Note [Decomposing TyConApp equalities] describes, if N is injective
at role r, we can do this decomposition?
   [G/W] (N ty1) ~r (N ty2)    to     [G/W]  ty1 ~r' ty2

For a Given with r=R, the answer is a solid NO: newtypes are not injective at
representational role, and we must not decompose, or we lose soundness.
Example is wrinkle {1} in Note [Decomposing TyConApp equalities].

For a Wanted with r=R, since newtypes are not injective at representational
role, decomposition is sound, but we may lose completeness.  Nevertheless,
if the newtype is abstract (so can't be unwrapped) we can only solve
the equality by (a) using a Given or (b) decomposition.  If (a) is impossible
(e.g. no Givens) then (b) is safe albeit potentially incomplete.

There are two ways in which decomposing (N ty1) ~r (N ty2) could be incomplete:

* Incompleteness example (EX1): unwrap first
      newtype Nt a = MkNt (Id a)
      type family Id a where Id a = a

      [W] Nt Int ~R Nt Age

  Because of its use of a type family, Nt's parameter will get inferred to
  have a nominal role. Thus, decomposing the wanted will yield [W] Int ~N Age,
  which is unsatisfiable. Unwrapping, though, leads to a solution.

  Conclusion: always unwrap newtypes before attempting to decompose
  them.  This is done in can_eq_nc'.  Of course, we can't unwrap if the data
  constructor isn't in scope.  See Note [Unwrap newtypes first].

* Incompleteness example (EX2): available Givens
      newtype Nt a = Mk Bool         -- NB: a is not used in the RHS,
      type role Nt representational  -- but the user gives it an R role anyway

      [G] Nt t1 ~R Nt t2
      [W] Nt alpha ~R Nt beta

  We *don't* want to decompose to [W] alpha ~R beta, because it's possible
  that alpha and beta aren't representationally equal.  And if we figure
  out (elsewhere) that alpha:=t1 and beta:=t2, we can solve the Wanted
  from the Given.  This is somewhat similar to the question of overlapping
  Givens for class constraints: see Note [Instance and Given overlap] in
  GHC.Tc.Solver.Interact.

  Conclusion: don't decompose [W] N s ~R N t, if there are any Given
  equalities that could later solve it.

  But what precisely does it mean to say "any Given equalities that could
  later solve it"?

  In #22924 we had
     [G] f a ~R# a     [W] Const (f a) a ~R# Const a a
  where Const is an abstract newtype.  If we decomposed the newtype, we
  could solve.  Not-decomposing on the grounds that (f a ~R# a) might turn
  into (Const (f a) a ~R# Const a a) seems a bit silly.

  In #22331 we had
     [G] N a ~R# N b   [W] N b ~R# N a
  (where N is abstract so we can't unwrap). Here we really /don't/ want to
  decompose, because the /only/ way to solve the Wanted is from that Given
  (with a Sym).

  In #22519 we had
     [G] a <= b     [W] IO Age ~R# IO Int

  (where IO is abstract so we can't unwrap, and newtype Age = Int; and (<=)
  is a type-level comparison on Nats).  Here we /must/ decompose, despite the
  existence of an Irred Given, or we will simply be stuck.  (Side note: We
  flirted with deep-rewriting of newtypes (see discussion on #22519 and
  !9623) but that turned out not to solve #22924, and also makes type
  inference loop more often on recursive newtypes.)

  The currently-implemented compromise is this:

    we decompose [W] N s ~R# N t unless there is a [G] N s' ~ N t'

  that is, a Given Irred equality with both sides headed with N.
  See the call to noGivenNewtypeReprEqs in canTyConApp.

  This is not perfect.  In principle a Given like [G] (a b) ~ (c d), or
  even just [G] c, could later turn into N s ~ N t.  But since the free
  vars of a Given are skolems, or at least untouchable unification
  variables, this is extremely unlikely to happen.

  Another worry: there could, just, be a CDictCan with some
  un-expanded equality superclasses; but only in some very obscure
  recursive-superclass situations.

   Yet another approach (!) is desribed in
   Note [Decomposing newtypes a bit more aggressively].

Remember: decomposing Wanteds is always /sound/. This Note is
only about /completeness/.

Note [Decomposing newtypes a bit more aggressively]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
IMPORTANT: the ideas in this Note are *not* implemented. Instead, the
current approach is detailed in Note [Decomposing newtype equalities]
and Note [Unwrap newtypes first].
For more details about the ideas in this Note see
  * GHC propoosal: https://github.com/ghc-proposals/ghc-proposals/pull/549
  * issue #22441
  * discussion on !9282.

Consider [G] c, [W] (IO Int) ~R (IO Age)
where IO is abstract, and
   newtype Age = MkAge Int   -- Not abstract
With the above rules, if there any Given Irreds,
the Wanted is insoluble because we can't decompose it.  But in fact,
if we look at the defn of IO, roughly,
    newtype IO a = State# -> (State#, a)
we can see that decomposing [W] (IO Int) ~R (IO Age) to
    [W] Int ~R Age
definitely does not lose completeness. Why not? Because the role of
IO's argment is representational.  Hence:

  DecomposeNewtypeIdea:
     decompose [W] (N s1 .. sn) ~R (N t1 .. tn)
     if the roles of all N's arguments are representational

If N's arguments really /are/ representational this will not lose
completeness.  Here "really are representational" means "if you expand
all newtypes in N's RHS, we'd infer a representational role for each
of N's type variables in that expansion".  See Note [Role inference]
in GHC.Tc.TyCl.Utils.

But the user might /override/ a phantom role with an explicit role
annotation, and then we could (obscurely) get incompleteness.
Consider

   module A( silly, T ) where
     newtype T a = MkT Int
     type role T representational  -- Override phantom role

     silly :: Coercion (T Int) (T Bool)
     silly = Coercion  -- Typechecks by unwrapping the newtype

     data Coercion a b where  -- Actually defined in Data.Type.Coercion
       Coercion :: Coercible a b => Coercion a b

   module B where
     import A
     f :: T Int -> T Bool
     f = case silly of Coercion -> coerce

Here the `coerce` gives [W] (T Int) ~R (T Bool) which, if we decompose,
we'll get stuck with (Int ~R Bool).  Instead we want to use the
[G] (T Int) ~R (T Bool), which will be in the Irreds.

Summary: we could adopt (DecomposeNewtypeIdea), at the cost of a very
obscure incompleteness (above).  But no one is reporting a problem from
the lack of decompostion, so we'll just leave it for now.  This long
Note is just to record the thinking for our future selves.

Note [Decomposing AppTy equalities]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
For AppTy all the same questions arise as in
Note [Decomposing TyConApp equalities]. We have

    s1 ~r s2,  t1 ~N t2   ==>   s1 t1 ~r s2 t2       (rule CO_APP)
    s1 t1 ~N s2 t2        ==>   s1 ~N s2,  t1 ~N t2  (CO_LEFT, CO_RIGHT)

In the first of these, why do we need Nominal equality in (t1 ~N t2)?
See {2} below.

For sound and complete solving, we need both directions to decompose. So:
* At nominal role, all is well: we have both directions.
* At representational role, decomposition of Givens is unsound (see {1} below),
  and decomposition of Wanteds is incomplete.

Here is an example of the incompleteness for Wanteds:

    [G] g1 :: a ~R b
    [W] w1 :: Maybe b ~R alpha a
    [W] w2 :: alpha ~N Maybe

Suppose we see w1 before w2. If we decompose, using AppCo to prove w1, we get

    w1 := AppCo w3 w4
    [W] w3 :: Maybe ~R alpha
    [W] w4 :: b ~N a

Note that w4 is *nominal*. A nominal role here is necessary because AppCo
requires a nominal role on its second argument. (See {2} for an example of
why.) Now we are stuck, because w4 is insoluble. On the other hand, if we
see w2 first, setting alpha := Maybe, all is well, as we can decompose
Maybe b ~R Maybe a into b ~R a.

Another example:
    newtype Phant x = MkPhant Int
    [W] w1 :: Phant Int ~R alpha Bool
    [W] w2 :: alpha ~ Phant

If we see w1 first, decomposing would be disastrous, as we would then try
to solve Int ~ Bool. Instead, spotting w2 allows us to simplify w1 to become
    [W] w1' :: Phant Int ~R Phant Bool

which can then (assuming MkPhant is in scope) be simplified to Int ~R Int,
and all will be well. See also Note [Unwrap newtypes first].

Bottom line:
* Always decompose AppTy at nominal role: can_eq_app
* Never decompose AppTy at representational role (neither Given nor Wanted):
  the lack of an equation in can_eq_nc'

Extra points
{1}  Decomposing a Given AppTy over a representational role is simply
     unsound. For example, if we have co1 :: Phant Int ~R a Bool (for
     the newtype Phant, above), then we surely don't want any relationship
     between Int and Bool, lest we also have co2 :: Phant ~ a around.

{2} The role on the AppCo coercion is a conservative choice, because we don't
    know the role signature of the function. For example, let's assume we could
    have a representational role on the second argument of AppCo. Then, consider

    data G a where    -- G will have a nominal role, as G is a GADT
      MkG :: G Int
    newtype Age = MkAge Int

    co1 :: G ~R a        -- by assumption
    co2 :: Age ~R Int    -- by newtype axiom
    co3 = AppCo co1 co2 :: G Age ~R a Int    -- by our broken AppCo

    and now co3 can be used to cast MkG to have type G Age, in violation of
    the way GADTs are supposed to work (which is to use nominal equality).
-}

canDecomposableTyConAppOK :: CtEvidence -> EqRel
                          -> TyCon -> [TcType] -> [TcType]
                          -> TcS (StopOrContinue Ct)
-- Precondition: tys1 and tys2 are the same finite length, hence "OK"
canDecomposableTyConAppOK ev eq_rel tc tys1 tys2
  = assert (tys1 `equalLength` tys2) $
    do { traceTcS "canDecomposableTyConAppOK"
                  (ppr ev $$ ppr eq_rel $$ ppr tc $$ ppr tys1 $$ ppr tys2)
       ; case ev of
           CtWanted { ctev_dest = dest, ctev_rewriters = rewriters }
                  -- new_locs and tc_roles are both infinite, so
                  -- we are guaranteed that cos has the same lengthm
                  -- as tys1 and tys2
                  -- See Note [Fast path when decomposing TyConApps]
                  -- Caution: unifyWanteds is order sensitive
                  -- See Note [Decomposing Dependent TyCons and Processing Wanted Equalities]
             -> do { cos <- unifyWanteds rewriters new_locs tc_roles tys1 tys2
                   ; setWantedEq dest (mkTyConAppCo role tc cos) }

           CtGiven { ctev_evar = evar }
             -> do { let ev_co = mkCoVarCo evar
                   ; given_evs <- newGivenEvVars loc $
                                  [ ( mkPrimEqPredRole r ty1 ty2
                                    , evCoercion $ mkSelCo (SelTyCon i r) ev_co )
                                  | (r, ty1, ty2, i) <- zip4 tc_roles tys1 tys2 [0..]
                                  , r /= Phantom
                                  , not (isCoercionTy ty1) && not (isCoercionTy ty2) ]
                   ; emitWorkNC given_evs }

    ; stopWith ev "Decomposed TyConApp" }

  where
    loc  = ctEvLoc ev
    role = eqRelRole eq_rel

    -- Infinite, to allow for over-saturated TyConApps
    tc_roles = tyConRoleListX role tc

      -- Add nuances to the location during decomposition:
      --  * if the argument is a kind argument, remember this, so that error
      --    messages say "kind", not "type". This is determined based on whether
      --    the corresponding tyConBinder is named (that is, dependent)
      --  * if the argument is invisible, note this as well, again by
      --    looking at the corresponding binder
      -- For oversaturated tycons, we need the (repeat loc) tail, which doesn't
      -- do either of these changes. (Forgetting to do so led to #16188)
      --
      -- NB: infinite in length
    new_locs = [ new_loc
               | bndr <- tyConBinders tc
               , let new_loc0 | isNamedTyConBinder bndr = toKindLoc loc
                              | otherwise               = loc
                     new_loc  | isInvisibleTyConBinder bndr
                              = updateCtLocOrigin new_loc0 toInvisibleOrigin
                              | otherwise
                              = new_loc0 ]
               ++ repeat loc

canDecomposableFunTy :: CtEvidence -> EqRel -> FunTyFlag
                     -> (Type,Type,Type)   -- (multiplicity,arg,res)
                     -> (Type,Type,Type)   -- (multiplicity,arg,res)
                     -> TcS (StopOrContinue Ct)
canDecomposableFunTy ev eq_rel af f1@(m1,a1,r1) f2@(m2,a2,r2)
  = do { traceTcS "canDecomposableFunTy"
                  (ppr ev $$ ppr eq_rel $$ ppr f1 $$ ppr f2)
       ; case ev of
           CtWanted { ctev_dest = dest, ctev_rewriters = rewriters }
             -> do { mult <- unifyWanted rewriters mult_loc (funRole role SelMult) m1 m2
                   ; arg  <- unifyWanted rewriters loc      (funRole role SelArg)  a1 a2
                   ; res  <- unifyWanted rewriters loc      (funRole role SelRes)  r1 r2
                   ; setWantedEq dest (mkNakedFunCo1 role af mult arg res) }

           CtGiven { ctev_evar = evar }
             -> do { let ev_co = mkCoVarCo evar
                   ; given_evs <- newGivenEvVars loc $
                                  [ ( mkPrimEqPredRole role' ty1 ty2
                                    , evCoercion $ mkSelCo (SelFun fs) ev_co )
                                  | (fs, ty1, ty2) <- [(SelMult, m1, m2)
                                                      ,(SelArg,  a1, a2)
                                                      ,(SelRes,  r1, r2)]
                                  , let role' = funRole role fs ]
                   ; emitWorkNC given_evs }

    ; stopWith ev "Decomposed TyConApp" }

  where
    loc      = ctEvLoc ev
    role     = eqRelRole eq_rel
    mult_loc = updateCtLocOrigin loc toInvisibleOrigin

-- | Call when canonicalizing an equality fails, but if the equality is
-- representational, there is some hope for the future.
-- Examples in Note [Use canEqFailure in canDecomposableTyConApp]
canEqFailure :: CtEvidence -> EqRel
             -> TcType -> TcType -> TcS (StopOrContinue Ct)
canEqFailure ev NomEq ty1 ty2
  = canEqHardFailure ev ty1 ty2
canEqFailure ev ReprEq ty1 ty2
  = do { (redn1, rewriters1) <- rewrite ev ty1
       ; (redn2, rewriters2) <- rewrite ev ty2
            -- We must rewrite the types before putting them in the
            -- inert set, so that we are sure to kick them out when
            -- new equalities become available
       ; traceTcS "canEqFailure with ReprEq" $
         vcat [ ppr ev, ppr redn1, ppr redn2 ]
       ; new_ev <- rewriteEqEvidence (rewriters1 S.<> rewriters2) ev NotSwapped redn1 redn2
       ; continueWith (mkIrredCt ReprEqReason new_ev) }

-- | Call when canonicalizing an equality fails with utterly no hope.
canEqHardFailure :: CtEvidence
                 -> TcType -> TcType -> TcS (StopOrContinue Ct)
-- See Note [Make sure that insolubles are fully rewritten]
canEqHardFailure ev ty1 ty2
  = do { traceTcS "canEqHardFailure" (ppr ty1 $$ ppr ty2)
       ; (redn1, rewriters1) <- rewriteForErrors ev ty1
       ; (redn2, rewriters2) <- rewriteForErrors ev ty2
       ; new_ev <- rewriteEqEvidence (rewriters1 S.<> rewriters2) ev NotSwapped redn1 redn2
       ; continueWith (mkIrredCt ShapeMismatchReason new_ev) }

{-
Note [Canonicalising type applications]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Given (s1 t1) ~ ty2, how should we proceed?
The simple thing is to see if ty2 is of form (s2 t2), and
decompose.

However, over-eager decomposition gives bad error messages
for things like
   a b ~ Maybe c
   e f ~ p -> q
Suppose (in the first example) we already know a~Array.  Then if we
decompose the application eagerly, yielding
   a ~ Maybe
   b ~ c
we get an error        "Can't match Array ~ Maybe",
but we'd prefer to get "Can't match Array b ~ Maybe c".

So instead can_eq_wanted_app rewrites the LHS and RHS, in the hope of
replacing (a b) by (Array b), before using try_decompose_app to
decompose it.

Note [Make sure that insolubles are fully rewritten]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When an equality fails, we still want to rewrite the equality
all the way down, so that it accurately reflects
 (a) the mutable reference substitution in force at start of solving
 (b) any ty-binds in force at this point in solving
See Note [Rewrite insolubles] in GHC.Tc.Solver.InertSet.
And if we don't do this there is a bad danger that
GHC.Tc.Solver.applyTyVarDefaulting will find a variable
that has in fact been substituted.

Note [Do not decompose Given polytype equalities]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider [G] (forall a. t1 ~ forall a. t2).  Can we decompose this?
No -- what would the evidence look like?  So instead we simply discard
this given evidence.

Note [No top-level newtypes on RHS of representational equalities]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Suppose we're in this situation:

 work item:  [W] c1 : a ~R b
     inert:  [G] c2 : b ~R Id a

where
  newtype Id a = Id a

We want to make sure canEqCanLHS sees [W] a ~R a, after b is rewritten
and the Id newtype is unwrapped. This is assured by requiring only rewritten
types in canEqCanLHS *and* having the newtype-unwrapping check above
the tyvar check in can_eq_nc.

Note that this only applies to saturated applications of newtype TyCons, as
we can't rewrite an unsaturated application. See for example T22310, where
we ended up with:

  newtype Compose f g a = ...

  [W] t[tau] ~# Compose Foo Bar

Note [Put touchable variables on the left]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Ticket #10009, a very nasty example:

    f :: (UnF (F b) ~ b) => F b -> ()

    g :: forall a. (UnF (F a) ~ a) => a -> ()
    g _ = f (undefined :: F a)

For g we get [G]  g1 : UnF (F a) ~ a
             [W] w1 : UnF (F beta) ~ beta
             [W] w2 : F a ~ F beta

g1 is canonical (CEqCan). It is oriented as above because a is not touchable.
See canEqTyVarFunEq.

w1 is similarly canonical, though the occurs-check in canEqTyVarFunEq is key
here.

w2 is canonical. But which way should it be oriented? As written, we'll be
stuck. When w2 is added to the inert set, nothing gets kicked out: g1 is
a Given (and Wanteds don't rewrite Givens), and w2 doesn't mention the LHS
of w2. We'll thus lose.

But if w2 is swapped around, to

    [W] w3 : F beta ~ F a

then we'll kick w1 out of the inert
set (it mentions the LHS of w3). We then rewrite w1 to

    [W] w4 : UnF (F a) ~ beta

and then, using g1, to

    [W] w5 : a ~ beta

at which point we can unify and go on to glory. (This rewriting actually
happens all at once, in the call to rewrite during canonicalisation.)

But what about the new LHS makes it better? It mentions a variable (beta)
that can appear in a Wanted -- a touchable metavariable never appears
in a Given. On the other hand, the original LHS mentioned only variables
that appear in Givens. We thus choose to put variables that can appear
in Wanteds on the left.

Ticket #12526 is another good example of this in action.

-}

---------------------
canEqCanLHS :: CtEvidence            -- ev :: lhs ~ rhs
            -> EqRel -> SwapFlag
            -> CanEqLHS              -- lhs (or, if swapped, rhs)
            -> TcType                -- lhs: pretty lhs, already rewritten
            -> TcType -> TcType      -- rhs: already rewritten
            -> TcS (StopOrContinue Ct)
canEqCanLHS ev eq_rel swapped lhs1 ps_xi1 xi2 ps_xi2
  | k1 `tcEqType` k2
  = canEqCanLHSHomo ev eq_rel swapped lhs1 ps_xi1 xi2 ps_xi2

  | otherwise
  = canEqCanLHSHetero ev eq_rel swapped lhs1 k1 xi2 k2

  where
    k1 = canEqLHSKind lhs1
    k2 = typeKind xi2


{-
Note [Kind Equality Orientation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
While in theory [W] x ~ y and [W] y ~ x ought to give us the same behaviour, in practice it does not.
See Note [Fundeps with instances, and equality orientation] where this is discussed at length.
As a rule of thumb: we keep the newest unification variables on the left of the equality.
See also Note [Improvement orientation] in GHC.Tc.Solver.Interact.

In particular, `canEqCanLHSHetero` produces the following constraint equalities

[X] (xi1 :: ki1) ~ (xi2 :: ki2)
  -->  [X] kco :: ki1 ~ ki2
       [X] co : xi1 :: ki1 ~ (xi2 |> sym kco) :: ki1

Note that the types in the LHS of the new constraints are the ones that were on the LHS of
the original constraint.

--- Historical note ---
We prevously used to flip the kco to avoid using a sym in the cast

[X] (xi1 :: ki1) ~ (xi2 :: ki2)
  -->  [X] kco :: ki2 ~ ki1
       [X] co : xi1 :: ki1 ~ (xi2 |> kco) :: ki1

But this sent solver in an infinite loop (see #19415).
-- End of historical note --
-}

canEqCanLHSHetero :: CtEvidence         -- :: (xi1 :: ki1) ~ (xi2 :: ki2)
                  -> EqRel -> SwapFlag
                  -> CanEqLHS           -- xi1
                  -> TcKind             -- ki1
                  -> TcType             -- xi2
                  -> TcKind             -- ki2
                  -> TcS (StopOrContinue Ct)
canEqCanLHSHetero ev eq_rel swapped lhs1 ki1 xi2 ki2
  -- See Note [Equalities with incompatible kinds]
  -- See Note [Kind Equality Orientation]
  -- NB: preserve left-to-right orientation!!
  -- See Note [Fundeps with instances, and equality orientation]
  --     wrinkle (W2) in GHC.Tc.Solver.Interact
  = do { (kind_ev, kind_co) <- mk_kind_eq   -- :: ki1 ~N ki2

       ; let  -- kind_co :: (ki1 :: *) ~N (ki2 :: *)   (whether swapped or not)
             lhs_redn = mkReflRedn role xi1
             rhs_redn = mkGReflRightRedn role xi2 (mkSymCo kind_co)

             -- See Note [Equalities with incompatible kinds], Wrinkle (1)
             -- This will be ignored in rewriteEqEvidence if the work item is a Given
             rewriters = rewriterSetFromCo kind_co

       ; traceTcS "Hetero equality gives rise to kind equality"
           (ppr kind_co <+> dcolon <+> sep [ ppr ki1, text "~#", ppr ki2 ])
       ; type_ev <- rewriteEqEvidence rewriters ev swapped lhs_redn rhs_redn

       ; emitWorkNC [type_ev]  -- delay the type equality until after we've finished
                               -- the kind equality, which may unlock things
                               -- See Note [Equalities with incompatible kinds]

       ; canEqNC kind_ev NomEq ki1 ki2 }
  where
    mk_kind_eq :: TcS (CtEvidence, CoercionN)
    mk_kind_eq = case ev of
      CtGiven { ctev_evar = evar }
        -> do { let kind_co = maybe_sym $ mkKindCo (mkCoVarCo evar) -- :: k1 ~ k2
              ; kind_ev <- newGivenEvVar kind_loc (kind_pty, evCoercion kind_co)
              ; return (kind_ev, ctEvCoercion kind_ev) }

      CtWanted { ctev_rewriters = rewriters }
        -> newWantedEq kind_loc rewriters Nominal ki1 ki2

    xi1      = canEqLHSType lhs1
    loc      = ctev_loc ev
    role     = eqRelRole eq_rel
    kind_loc = mkKindLoc xi1 xi2 loc
    kind_pty = mkHeteroPrimEqPred liftedTypeKind liftedTypeKind ki1 ki2

    maybe_sym = case swapped of
          IsSwapped  -> mkSymCo         -- if the input is swapped, then we
                                        -- will have k2 ~ k1, so flip it to k1 ~ k2
          NotSwapped -> id

-- guaranteed that typeKind lhs == typeKind rhs
canEqCanLHSHomo :: CtEvidence
                -> EqRel -> SwapFlag
                -> CanEqLHS           -- lhs (or, if swapped, rhs)
                -> TcType             -- pretty lhs
                -> TcType -> TcType   -- rhs, pretty rhs
                -> TcS (StopOrContinue Ct)
canEqCanLHSHomo ev eq_rel swapped lhs1 ps_xi1 xi2 ps_xi2
  | (xi2', mco) <- split_cast_ty xi2
  , Just lhs2 <- canEqLHS_maybe xi2'
  = canEqCanLHS2 ev eq_rel swapped lhs1 ps_xi1 lhs2 (ps_xi2 `mkCastTyMCo` mkSymMCo mco) mco

  | otherwise
  = canEqCanLHSFinish ev eq_rel swapped lhs1 ps_xi2

  where
    split_cast_ty (CastTy ty co) = (ty, MCo co)
    split_cast_ty other          = (other, MRefl)

-- This function deals with the case that both LHS and RHS are potential
-- CanEqLHSs.
canEqCanLHS2 :: CtEvidence              -- lhs ~ (rhs |> mco)
                                        -- or, if swapped: (rhs |> mco) ~ lhs
             -> EqRel -> SwapFlag
             -> CanEqLHS                -- lhs (or, if swapped, rhs)
             -> TcType                  -- pretty lhs
             -> CanEqLHS                -- rhs
             -> TcType                  -- pretty rhs
             -> MCoercion               -- :: kind(rhs) ~N kind(lhs)
             -> TcS (StopOrContinue Ct)
canEqCanLHS2 ev eq_rel swapped lhs1 ps_xi1 lhs2 ps_xi2 mco
  | lhs1 `eqCanEqLHS` lhs2
    -- It must be the case that mco is reflexive
  = canEqReflexive ev eq_rel (canEqLHSType lhs1)

  | TyVarLHS tv1 <- lhs1
  , TyVarLHS tv2 <- lhs2
  , swapOverTyVars (isGiven ev) tv1 tv2
  = do { traceTcS "canEqLHS2 swapOver" (ppr tv1 $$ ppr tv2 $$ ppr swapped)
       ; new_ev <- do_swap
       ; canEqCanLHSFinish new_ev eq_rel IsSwapped (TyVarLHS tv2)
                                                   (ps_xi1 `mkCastTyMCo` sym_mco) }

  | TyVarLHS tv1 <- lhs1
  , TyFamLHS fun_tc2 fun_args2 <- lhs2
  = canEqTyVarFunEq ev eq_rel swapped tv1 ps_xi1 fun_tc2 fun_args2 ps_xi2 mco

  | TyFamLHS fun_tc1 fun_args1 <- lhs1
  , TyVarLHS tv2 <- lhs2
  = do { new_ev <- do_swap
       ; canEqTyVarFunEq new_ev eq_rel IsSwapped tv2 ps_xi2
                                                 fun_tc1 fun_args1 ps_xi1 sym_mco }

  | TyFamLHS fun_tc1 fun_args1 <- lhs1
  , TyFamLHS fun_tc2 fun_args2 <- lhs2
  -- See Note [Decomposing type family applications]
  = do { traceTcS "canEqCanLHS2 two type families" (ppr lhs1 $$ ppr lhs2)

         -- emit wanted equalities for injective type families
       ; let inj_eqns :: [TypeEqn]  -- TypeEqn = Pair Type
             inj_eqns
               | ReprEq <- eq_rel   = []   -- injectivity applies only for nom. eqs.
               | fun_tc1 /= fun_tc2 = []   -- if the families don't match, stop.

               | Injective inj <- tyConInjectivityInfo fun_tc1
               = [ Pair arg1 arg2
                 | (arg1, arg2, True) <- zip3 fun_args1 fun_args2 inj ]

                 -- built-in synonym families don't have an entry point
                 -- for this use case. So, we just use sfInteractInert
                 -- and pass two equal RHSs. We *could* add another entry
                 -- point, but then there would be a burden to make
                 -- sure the new entry point and existing ones were
                 -- internally consistent. This is slightly distasteful,
                 -- but it works well in practice and localises the
                 -- problem.
               | Just ops <- isBuiltInSynFamTyCon_maybe fun_tc1
               = let ki1 = canEqLHSKind lhs1
                     ki2 | MRefl <- mco
                         = ki1   -- just a small optimisation
                         | otherwise
                         = canEqLHSKind lhs2

                     fake_rhs1 = anyTypeOfKind ki1
                     fake_rhs2 = anyTypeOfKind ki2
                 in
                 sfInteractInert ops fun_args1 fake_rhs1 fun_args2 fake_rhs2

               | otherwise  -- ordinary, non-injective type family
               = []

       ; case ev of
           CtWanted { ctev_rewriters = rewriters } ->
             mapM_ (\ (Pair t1 t2) -> unifyWanted rewriters (ctEvLoc ev) Nominal t1 t2) inj_eqns
           CtGiven {} -> return ()
             -- See Note [No Given/Given fundeps] in GHC.Tc.Solver.Interact

       ; tclvl <- getTcLevel
       ; let tvs1 = tyCoVarsOfTypes fun_args1
             tvs2 = tyCoVarsOfTypes fun_args2

             swap_for_rewriting = anyVarSet (isTouchableMetaTyVar tclvl) tvs2 &&
                          -- swap 'em: Note [Put touchable variables on the left]
                                  not (anyVarSet (isTouchableMetaTyVar tclvl) tvs1)
                          -- this check is just to avoid unfruitful swapping

               -- If we have F a ~ F (F a), we want to swap.
             swap_for_occurs
               | cterHasNoProblem   $ checkTyFamEq fun_tc2 fun_args2
                                                   (mkTyConApp fun_tc1 fun_args1)
               , cterHasOccursCheck $ checkTyFamEq fun_tc1 fun_args1
                                                   (mkTyConApp fun_tc2 fun_args2)
               = True

               | otherwise
               = False

       ; if swap_for_rewriting || swap_for_occurs
         then do { new_ev <- do_swap
                 ; canEqCanLHSFinish new_ev eq_rel IsSwapped lhs2 (ps_xi1 `mkCastTyMCo` sym_mco) }
         else finish_without_swapping }

  -- that's all the special cases. Now we just figure out which non-special case
  -- to continue to.
  | otherwise
  = finish_without_swapping

  where
    sym_mco = mkSymMCo mco

    do_swap = rewriteCastedEquality ev eq_rel swapped (canEqLHSType lhs1) (canEqLHSType lhs2) mco
    finish_without_swapping = canEqCanLHSFinish ev eq_rel swapped lhs1 (ps_xi2 `mkCastTyMCo` mco)


-- This function handles the case where one side is a tyvar and the other is
-- a type family application. Which to put on the left?
--   If the tyvar is a touchable meta-tyvar, put it on the left, as this may
--   be our only shot to unify.
--   Otherwise, put the function on the left, because it's generally better to
--   rewrite away function calls. This makes types smaller. And it seems necessary:
--     [W] F alpha ~ alpha
--     [W] F alpha ~ beta
--     [W] G alpha beta ~ Int   ( where we have type instance G a a = a )
--   If we end up with a stuck alpha ~ F alpha, we won't be able to solve this.
--   Test case: indexed-types/should_compile/CEqCanOccursCheck
canEqTyVarFunEq :: CtEvidence               -- :: lhs ~ (rhs |> mco)
                                            -- or (rhs |> mco) ~ lhs if swapped
                -> EqRel -> SwapFlag
                -> TyVar -> TcType          -- lhs (or if swapped rhs), pretty lhs
                -> TyCon -> [Xi] -> TcType  -- rhs (or if swapped lhs) fun and args, pretty rhs
                -> MCoercion                -- :: kind(rhs) ~N kind(lhs)
                -> TcS (StopOrContinue Ct)
canEqTyVarFunEq ev eq_rel swapped tv1 ps_xi1 fun_tc2 fun_args2 ps_xi2 mco
  = do { (is_touchable, rhs) <- touchabilityTest (ctEvFlavour ev) tv1 rhs
       ; if | case is_touchable of { Untouchable -> False; _ -> True }
            , cterHasNoProblem $
                checkTyVarEq tv1 rhs `cterRemoveProblem` cteTypeFamily
            -> canEqCanLHSFinish ev eq_rel swapped (TyVarLHS tv1) rhs

            | otherwise
              -> do { new_ev <- rewriteCastedEquality ev eq_rel swapped
                                  (mkTyVarTy tv1) (mkTyConApp fun_tc2 fun_args2)
                                  mco
                    ; canEqCanLHSFinish new_ev eq_rel IsSwapped
                                  (TyFamLHS fun_tc2 fun_args2)
                                  (ps_xi1 `mkCastTyMCo` sym_mco) } }
  where
    sym_mco = mkSymMCo mco
    rhs = ps_xi2 `mkCastTyMCo` mco

-- The RHS here is either not CanEqLHS, or it's one that we
-- want to rewrite the LHS to (as per e.g. swapOverTyVars)
canEqCanLHSFinish :: CtEvidence
                  -> EqRel -> SwapFlag
                  -> CanEqLHS             -- lhs (or, if swapped, rhs)
                  -> TcType               -- rhs (or, if swapped, lhs)
                  -> TcS (StopOrContinue Ct)
canEqCanLHSFinish ev eq_rel swapped lhs rhs
-- RHS is fully rewritten, but with type synonyms
-- preserved as much as possible
-- guaranteed that tyVarKind lhs == typeKind rhs, for (TyEq:K)
-- (TyEq:N) is checked in can_eq_nc', and (TyEq:TV) is handled in canEqCanLHS2

  = do {
          -- this performs the swap if necessary
         new_ev <- rewriteEqEvidence emptyRewriterSet ev swapped
                                     (mkReflRedn role lhs_ty)
                                     (mkReflRedn role rhs)

     -- by now, (TyEq:K) is already satisfied
       ; massert (canEqLHSKind lhs `eqType` typeKind rhs)

     -- by now, (TyEq:N) is already satisfied (if applicable)
       ; assertPprM ty_eq_N_OK $
           vcat [ text "CanEqCanLHSFinish: (TyEq:N) not satisfied"
                , text "rhs:" <+> ppr rhs
                ]

     -- guarantees (TyEq:OC), (TyEq:F)
     -- Must do the occurs check even on tyvar/tyvar
     -- equalities, in case have  x ~ (y :: ..x...); this is #12593.
       ; let result0 = checkTypeEq lhs rhs `cterRemoveProblem` cteTypeFamily
     -- type families are OK here
     -- NB: no occCheckExpand here; see Note [Rewriting synonyms] in GHC.Tc.Solver.Rewrite

              -- a ~R# b a is soluble if b later turns out to be Identity
             result = case eq_rel of
                        NomEq  -> result0
                        ReprEq -> cterSetOccursCheckSoluble result0

             reason = NonCanonicalReason result

       ; if cterHasNoProblem result
         then do { traceTcS "CEqCan" (ppr lhs $$ ppr rhs)
                 ; continueWith (CEqCan { cc_ev = new_ev, cc_lhs = lhs
                                        , cc_rhs = rhs, cc_eq_rel = eq_rel }) }

         else do { m_stuff <- breakTyEqCycle_maybe ev result lhs rhs
                           -- See Note [Type equality cycles];
                           -- returning Nothing is the vastly common case
                 ; case m_stuff of
                     { Nothing ->
                         do { traceTcS "canEqCanLHSFinish can't make a canonical"
                                       (ppr lhs $$ ppr rhs)
                            ; continueWith (mkIrredCt reason new_ev) }
                     ; Just rhs_redn@(Reduction _ new_rhs) ->
              do { traceTcS "canEqCanLHSFinish breaking a cycle" $
                            ppr lhs $$ ppr rhs
                 ; traceTcS "new RHS:" (ppr new_rhs)

                   -- This check is Detail (1) in the Note
                 ; if cterHasOccursCheck (checkTypeEq lhs new_rhs)

                   then do { traceTcS "Note [Type equality cycles] Detail (1)"
                                      (ppr new_rhs)
                           ; continueWith (mkIrredCt reason new_ev) }

                   else do { -- See Detail (6) of Note [Type equality cycles]
                             new_new_ev <- rewriteEqEvidence emptyRewriterSet
                                             new_ev NotSwapped
                                             (mkReflRedn Nominal lhs_ty)
                                             rhs_redn

                           ; continueWith (CEqCan { cc_ev = new_new_ev
                                                  , cc_lhs = lhs
                                                  , cc_rhs = new_rhs
                                                  , cc_eq_rel = eq_rel }) }}}}}
  where
    role = eqRelRole eq_rel

    lhs_ty = canEqLHSType lhs

    -- This is about (TyEq:N): check that we don't have a saturated application
    -- of a newtype TyCon at the top level of the RHS, if the constructor
    -- of the newtype is in scope.
    ty_eq_N_OK :: TcS Bool
    ty_eq_N_OK
      | ReprEq <- eq_rel
      , Just (tc, tc_args) <- splitTyConApp_maybe rhs
      , Just con <- newTyConDataCon_maybe tc
      -- #22310: only a problem if the newtype TyCon is saturated.
      , tc_args `lengthAtLeast` tyConArity tc
      -- #21010: only a problem if the newtype constructor is in scope.
      = do { rdr_env <- getGlobalRdrEnvTcS
           ; let con_in_scope = isJust $ lookupGRE_Name rdr_env (dataConName con)
           ; return $ not con_in_scope }
      | otherwise
      = return True

-- | Solve a reflexive equality constraint
canEqReflexive :: CtEvidence    -- ty ~ ty
               -> EqRel
               -> TcType        -- ty
               -> TcS (StopOrContinue Ct)   -- always Stop
canEqReflexive ev eq_rel ty
  = do { setEvBindIfWanted ev (evCoercion $
                               mkReflCo (eqRelRole eq_rel) ty)
       ; stopWith ev "Solved by reflexivity" }

rewriteCastedEquality :: CtEvidence     -- :: lhs ~ (rhs |> mco), or (rhs |> mco) ~ lhs
                      -> EqRel -> SwapFlag
                      -> TcType         -- lhs
                      -> TcType         -- rhs
                      -> MCoercion      -- mco
                      -> TcS CtEvidence -- :: (lhs |> sym mco) ~ rhs
                                        -- result is independent of SwapFlag
rewriteCastedEquality ev eq_rel swapped lhs rhs mco
  = rewriteEqEvidence emptyRewriterSet ev swapped lhs_redn rhs_redn
  where
    lhs_redn = mkGReflRightMRedn role lhs sym_mco
    rhs_redn = mkGReflLeftMRedn  role rhs mco

    sym_mco = mkSymMCo mco
    role    = eqRelRole eq_rel

{- Note [Equalities with incompatible kinds]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
What do we do when we have an equality

  (tv :: k1) ~ (rhs :: k2)

where k1 and k2 differ? Easy: we create a coercion that relates k1 and
k2 and use this to cast. To wit, from

  [X] (tv :: k1) ~ (rhs :: k2)

(where [X] is [G] or [W]), we go to

  [X] co :: k1 ~ k2
  [X] (tv :: k1) ~ ((rhs |> sym co) :: k1)

We carry on with the *kind equality*, not the type equality, because
solving the former may unlock the latter. This choice is made in
canEqCanLHSHetero. It is important: otherwise, T13135 loops.

Wrinkles:

 (1) When X is W, the new type-level wanted is effectively rewritten by the
     kind-level one. We thus include the kind-level wanted in the RewriterSet
     for the type-level one. See Note [Wanteds rewrite Wanteds] in GHC.Tc.Types.Constraint.
     This is done in canEqCanLHSHetero.

 (2) If we have [W] w :: alpha ~ (rhs |> sym co_hole), should we unify alpha? No.
     The problem is that the wanted w is effectively rewritten by another wanted,
     and unifying alpha effectively promotes this wanted to a given. Doing so
     means we lose track of the rewriter set associated with the wanted.

     On the other hand, w is perfectly suitable for rewriting, because of the
     way we carefully track rewriter sets.

     We thus allow w to be a CEqCan, but we prevent unification. See
     Note [Unification preconditions] in GHC.Tc.Utils.Unify.

     The only tricky part is that we must later indeed unify if/when the kind-level
     wanted gets solved. This is done in kickOutAfterFillingCoercionHole,
     which kicks out all equalities whose RHS mentions the filled-in coercion hole.
     Note that it looks for type family equalities, too, because of the use of
     unifyTest in canEqTyVarFunEq.

 (3) Suppose we have [W] (a :: k1) ~ (rhs :: k2). We duly follow the
     algorithm detailed here, producing [W] co :: k1 ~ k2, and adding
     [W] (a :: k1) ~ ((rhs |> sym co) :: k1) to the irreducibles. Some time
     later, we solve co, and fill in co's coercion hole. This kicks out
     the irreducible as described in (2).
     But now, during canonicalization, we see the cast
     and remove it, in canEqCast. By the time we get into canEqCanLHS, the equality
     is heterogeneous again, and the process repeats.

     To avoid this, we don't strip casts off a type if the other type
     in the equality is a CanEqLHS (the scenario above can happen with a
     type family, too. testcase: typecheck/should_compile/T13822).
     And this is an improvement regardless:
     because tyvars can, generally, unify with casted types, there's no
     reason to go through the work of stripping off the cast when the
     cast appears opposite a tyvar. This is implemented in the cast case
     of can_eq_nc'.

Historical note:

We used to do this via emitting a Derived kind equality and then parking
the heterogeneous equality as irreducible. But this new approach is much
more direct. And it doesn't produce duplicate Deriveds (as the old one did).

Note [Type synonyms and canonicalization]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We treat type synonym applications as xi types, that is, they do not
count as type function applications.  However, we do need to be a bit
careful with type synonyms: like type functions they may not be
generative or injective.  However, unlike type functions, they are
parametric, so there is no problem in expanding them whenever we see
them, since we do not need to know anything about their arguments in
order to expand them; this is what justifies not having to treat them
as specially as type function applications.  The thing that causes
some subtleties is that we prefer to leave type synonym applications
*unexpanded* whenever possible, in order to generate better error
messages.

If we encounter an equality constraint with type synonym applications
on both sides, or a type synonym application on one side and some sort
of type application on the other, we simply must expand out the type
synonyms in order to continue decomposing the equality constraint into
primitive equality constraints.  For example, suppose we have

  type F a = [Int]

and we encounter the equality

  F a ~ [b]

In order to continue we must expand F a into [Int], giving us the
equality

  [Int] ~ [b]

which we can then decompose into the more primitive equality
constraint

  Int ~ b.

However, if we encounter an equality constraint with a type synonym
application on one side and a variable on the other side, we should
NOT (necessarily) expand the type synonym, since for the purpose of
good error messages we want to leave type synonyms unexpanded as much
as possible.  Hence the ps_xi1, ps_xi2 argument passed to canEqCanLHS.

Note [Type equality cycles]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider this situation (from indexed-types/should_compile/GivenLoop):

  instance C (Maybe b)
  *[G] a ~ Maybe (F a)
  [W] C a

or (typecheck/should_compile/T19682b):

  instance C (a -> b)
  *[W] alpha ~ (Arg alpha -> Res alpha)
  [W] C alpha

or (typecheck/should_compile/T21515):

  type family Code a
  *[G] Code a ~ '[ '[ Head (Head (Code a)) ] ]
  [W] Code a ~ '[ '[ alpha ] ]

In order to solve the final Wanted, we must use the starred constraint
for rewriting. But note that all starred constraints have occurs-check failures,
and so we can't straightforwardly add these to the inert set and
use them for rewriting. (NB: A rigid type constructor is at the
top of all RHSs, preventing reorienting in canEqTyVarFunEq in the tyvar
cases.)

The key idea is to replace the outermost type family applications in the RHS of the
starred constraints with a fresh variable, which we'll call a cycle-breaker
variable, or cbv. Then, relate the cbv back with the original type family application
via new equality constraints. Our situations thus become:

  instance C (Maybe b)
  [G] a ~ Maybe cbv
  [G] F a ~ cbv
  [W] C a

or

  instance C (a -> b)
  [W] alpha ~ (cbv1 -> cbv2)
  [W] Arg alpha ~ cbv1
  [W] Res alpha ~ cbv2
  [W] C alpha

or

  [G] Code a ~ '[ '[ cbv ] ]
  [G] Head (Head (Code a)) ~ cbv
  [W] Code a ~ '[ '[ alpha ] ]

This transformation (creating the new types and emitting new equality
constraints) is done in breakTyEqCycle_maybe.

The details depend on whether we're working with a Given or a Wanted.

Given
-----

We emit a new Given, [G] F a ~ cbv, equating the type family application to
our new cbv. Note its orientation: The type family ends up on the left; see
commentary on canEqTyVarFunEq, which decides how to orient such cases. No
special treatment for CycleBreakerTvs is necessary. This scenario is now
easily soluble, by using the first Given to rewrite the Wanted, which can now
be solved.

(The first Given actually also rewrites the second one, giving
[G] F (Maybe cbv) ~ cbv, but this causes no trouble.)

Of course, we don't want our fresh variables leaking into e.g. error messages.
So we fill in the metavariables with their original type family applications
after we're done running the solver (in nestImplicTcS and runTcSWithEvBinds).
This is done by restoreTyVarCycles, which uses the inert_cycle_breakers field in
InertSet, which contains the pairings invented in breakTyEqCycle_maybe.

That is:

We transform
  [G] g : lhs ~ ...(F lhs)...
to
  [G] (Refl lhs) : F lhs ~ cbv      -- CEqCan
  [G] g          : lhs ~ ...cbv...  -- CEqCan

Note that
* `cbv` is a fresh cycle breaker variable.
* `cbv` is a is a meta-tyvar, but it is completely untouchable.
* We track the cycle-breaker variables in inert_cycle_breakers in InertSet
* We eventually fill in the cycle-breakers, with `cbv := F lhs`.
  No one else fills in cycle-breakers!
* The evidence for the new `F lhs ~ cbv` constraint is Refl, because we know
  this fill-in is ultimately going to happen.
* In inert_cycle_breakers, we remember the (cbv, F lhs) pair; that is, we
  remember the /original/ type.  The [G] F lhs ~ cbv constraint may be rewritten
  by other givens (eg if we have another [G] lhs ~ (b,c)), but at the end we
  still fill in with cbv := F lhs
* This fill-in is done when solving is complete, by restoreTyVarCycles
  in nestImplicTcS and runTcSWithEvBinds.

Wanted
------
The fresh cycle-breaker variables here must actually be normal, touchable
metavariables. That is, they are TauTvs. Nothing at all unusual. Repeating
the example from above, we have

  *[W] alpha ~ (Arg alpha -> Res alpha)

and we turn this into

  *[W] alpha ~ (cbv1 -> cbv2)
  [W] Arg alpha ~ cbv1
  [W] Res alpha ~ cbv2

where cbv1 and cbv2 are fresh TauTvs. Why TauTvs? See [Why TauTvs] below.

Critically, we emit the two new constraints (the last two above)
directly instead of calling unifyWanted. (Otherwise, we'd end up unifying cbv1
and cbv2 immediately, achieving nothing.)
Next, we unify alpha := cbv1 -> cbv2, having eliminated the occurs check. This
unification -- which must be the next step after breaking the cycles --
happens in the course of normal behavior of top-level
interactions, later in the solver pipeline. We know this unification will
indeed happen because breakTyEqCycle_maybe, which decides whether to apply
this logic, checks to ensure unification will succeed in its final_check.
(In particular, the LHS must be a touchable tyvar, never a type family. We don't
yet have an example of where this logic is needed with a type family, and it's
unclear how to handle this case, so we're skipping for now.) Now, we're
here (including further context from our original example, from the top of the
Note):

  instance C (a -> b)
  [W] Arg (cbv1 -> cbv2) ~ cbv1
  [W] Res (cbv1 -> cbv2) ~ cbv2
  [W] C (cbv1 -> cbv2)

The first two W constraints reduce to reflexivity and are discarded,
and the last is easily soluble.

[Why TauTvs]:
Let's look at another example (typecheck/should_compile/T19682) where we need
to unify the cbvs:

  class    (AllEqF xs ys, SameShapeAs xs ys) => AllEq xs ys
  instance (AllEqF xs ys, SameShapeAs xs ys) => AllEq xs ys

  type family SameShapeAs xs ys :: Constraint where
    SameShapeAs '[] ys      = (ys ~ '[])
    SameShapeAs (x : xs) ys = (ys ~ (Head ys : Tail ys))

  type family AllEqF xs ys :: Constraint where
    AllEqF '[]      '[]      = ()
    AllEqF (x : xs) (y : ys) = (x ~ y, AllEq xs ys)

  [W] alpha ~ (Head alpha : Tail alpha)
  [W] AllEqF '[Bool] alpha

Without the logic detailed in this Note, we're stuck here, as AllEqF cannot
reduce and alpha cannot unify. Let's instead apply our cycle-breaker approach,
just as described above. We thus invent cbv1 and cbv2 and unify
alpha := cbv1 -> cbv2, yielding (after zonking)

  [W] Head (cbv1 : cbv2) ~ cbv1
  [W] Tail (cbv1 : cbv2) ~ cbv2
  [W] AllEqF '[Bool] (cbv1 : cbv2)

The first two W constraints simplify to reflexivity and are discarded.
But the last reduces:

  [W] Bool ~ cbv1
  [W] AllEq '[] cbv2

The first of these is solved by unification: cbv1 := Bool. The second
is solved by the instance for AllEq to become

  [W] AllEqF '[] cbv2
  [W] SameShapeAs '[] cbv2

While the first of these is stuck, the second makes progress, to lead to

  [W] AllEqF '[] cbv2
  [W] cbv2 ~ '[]

This second constraint is solved by unification: cbv2 := '[]. We now
have

  [W] AllEqF '[] '[]

which reduces to

  [W] ()

which is trivially satisfiable. Hooray!

Note that we need to unify the cbvs here; if we did not, there would be
no way to solve those constraints. That's why the cycle-breakers are
ordinary TauTvs.

In all cases
------------

We detect this scenario by the following characteristics:
 - a constraint with a soluble occurs-check failure
   (as indicated by the cteSolubleOccurs bit set in a CheckTyEqResult
   from checkTypeEq)
 - and a nominal equality
 - and either
    - a Given flavour (but see also Detail (7) below)
    - a Wanted flavour, with a touchable metavariable on the left

We don't use this trick for representational equalities, as there is no
concrete use case where it is helpful (unlike for nominal equalities).
Furthermore, because function applications can be CanEqLHSs, but newtype
applications cannot, the disparities between the cases are enough that it
would be effortful to expand the idea to representational equalities. A quick
attempt, with

      data family N a b

      f :: (Coercible a (N a b), Coercible (N a b) b) => a -> b
      f = coerce

failed with "Could not match 'b' with 'b'." Further work is held off
until when we have a concrete incentive to explore this dark corner.

Details:

 (1) We don't look under foralls, at all, when substituting away type family
     applications, because doing so can never be fruitful. Recall that we
     are in a case like [G] lhs ~ forall b. ... lhs ....   Until we have a type
     family that can pull the body out from a forall (e.g. type instance F (forall b. ty) = ty),
     this will always be
     insoluble. Note also that the forall cannot be in an argument to a
     type family, or that outer type family application would already have
     been substituted away.

     However, we still must check to make sure that breakTyEqCycle_maybe actually
     succeeds in getting rid of all occurrences of the offending lhs. If
     one is hidden under a forall, this won't be true. A similar problem can
     happen if the variable appears only in a kind
     (e.g. k ~ ... (a :: k) ...). So we perform an additional check after
     performing the substitution. It is tiresome to re-run all of checkTypeEq
     here, but reimplementing just the occurs-check is even more tiresome.

     Skipping this check causes typecheck/should_fail/GivenForallLoop and
     polykinds/T18451 to loop.

 (2) Our goal here is to avoid loops in rewriting. We can thus skip looking
     in coercions, as we don't rewrite in coercions in the algorithm in
     GHC.Solver.Rewrite. (This is another reason
     we need to re-check that we've gotten rid of all occurrences of the
     offending variable.)

 (3) As we're substituting as described in this Note, we can build ill-kinded
     types. For example, if we have Proxy (F a) b, where (b :: F a), then
     replacing this with Proxy cbv b is ill-kinded. However, we will later
     set cbv := F a, and so the zonked type will be well-kinded again.
     The temporary ill-kinded type hurts no one, and avoiding this would
     be quite painfully difficult.

     Specifically, this detail does not contravene the Purely Kinded Type Invariant
     (Note [The Purely Kinded Type Invariant (PKTI)] in GHC.Tc.Gen.HsType).
     The PKTI says that we can call typeKind on any type, without failure.
     It would be violated if we, say, replaced a kind (a -> b) with a kind c,
     because an arrow kind might be consulted in piResultTys. Here, we are
     replacing one opaque type like (F a b c) with another, cbv (opaque in
     that we never assume anything about its structure, like that it has a
     result type or a RuntimeRep argument).

 (4) The evidence for the produced Givens is all just reflexive, because
     we will eventually set the cycle-breaker variable to be the type family,
     and then, after the zonk, all will be well. See also the notes at the
     end of the Given section of this Note.

 (5) The approach here is inefficient because it replaces every (outermost)
     type family application with a type variable, regardless of whether that
     particular appplication is implicated in the occurs check.  An alternative
     would be to replce only type-family applications that mention the offending LHS.
     For instance, we could choose to
     affect only type family applications that mention the offending LHS:
     e.g. in a ~ (F b, G a), we need to replace only G a, not F b. Furthermore,
     we could try to detect cases like a ~ (F a, F a) and use the same
     tyvar to replace F a. (Cf.
     Note [Flattening type-family applications when matching instances]
     in GHC.Core.Unify, which
     goes to this extra effort.) There may be other opportunities for
     improvement. However, this is really a very small corner case.
     The investment to craft a clever,
     performant solution seems unworthwhile.

 (6) We often get the predicate associated with a constraint from its
     evidence with ctPred. We thus must not only make sure the generated
     CEqCan's fields have the updated RHS type (that is, the one produced
     by replacing type family applications with fresh variables),
     but we must also update the evidence itself. This is done by the call to rewriteEqEvidence
     in canEqCanLHSFinish.

 (7) We don't wish to apply this magic on the equalities created
     by this very same process.
     Consider this, from typecheck/should_compile/ContextStack2:

       type instance TF (a, b) = (TF a, TF b)
       t :: (a ~ TF (a, Int)) => ...

       [G] a ~ TF (a, Int)

     The RHS reduces, so we get

       [G] a ~ (TF a, TF Int)

     We then break cycles, to get

       [G] g1 :: a ~ (cbv1, cbv2)
       [G] g2 :: TF a ~ cbv1
       [G] g3 :: TF Int ~ cbv2

     g1 gets added to the inert set, as written. But then g2 becomes
     the work item. g1 rewrites g2 to become

       [G] TF (cbv1, cbv2) ~ cbv1

     which then uses the type instance to become

       [G] (TF cbv1, TF cbv2) ~ cbv1

     which looks remarkably like the Given we started with. If left
     unchecked, this will end up breaking cycles again, looping ad
     infinitum (and resulting in a context-stack reduction error,
     not an outright loop). The solution is easy: don't break cycles
     on an equality generated by breaking cycles. Instead, we mark this
     final Given as a CIrredCan with a NonCanonicalReason with the soluble
     occurs-check bit set (only).

     We track these equalities by giving them a special CtOrigin,
     CycleBreakerOrigin. This works for both Givens and Wanteds, as
     we need the logic in the W case for e.g. typecheck/should_fail/T17139.
     Because this logic needs to work for Wanteds, too, we cannot
     simply look for a CycleBreakerTv on the left: Wanteds don't use them.

 (8) We really want to do this all only when there is a soluble occurs-check
     failure, not when other problems arise (such as an impredicative
     equality like alpha ~ forall a. a -> a). That is why breakTyEqCycle_maybe
     uses cterHasOnlyProblem when looking at the result of checkTypeEq, which
     checks for many of the invariants on a CEqCan.
-}

{-
************************************************************************
*                                                                      *
                  Evidence transformation
*                                                                      *
************************************************************************
-}

data StopOrContinue a
  = ContinueWith a    -- The constraint was not solved, although it may have
                      --   been rewritten

  | Stop CtEvidence   -- The (rewritten) constraint was solved
         SDoc         -- Tells how it was solved
                      -- Any new sub-goals have been put on the work list
  deriving (Functor)

instance Outputable a => Outputable (StopOrContinue a) where
  ppr (Stop ev s)      = text "Stop" <> parens s <+> ppr ev
  ppr (ContinueWith w) = text "ContinueWith" <+> ppr w

continueWith :: a -> TcS (StopOrContinue a)
continueWith = return . ContinueWith

stopWith :: CtEvidence -> String -> TcS (StopOrContinue a)
stopWith ev s = return (Stop ev (text s))

andWhenContinue :: TcS (StopOrContinue a)
                -> (a -> TcS (StopOrContinue b))
                -> TcS (StopOrContinue b)
andWhenContinue tcs1 tcs2
  = do { r <- tcs1
       ; case r of
           Stop ev s       -> return (Stop ev s)
           ContinueWith ct -> tcs2 ct }
infixr 0 `andWhenContinue`    -- allow chaining with ($)

rewriteEvidence :: RewriterSet  -- ^ See Note [Wanteds rewrite Wanteds]
                                -- in GHC.Tc.Types.Constraint
                -> CtEvidence   -- ^ old evidence
                -> Reduction    -- ^ new predicate + coercion, of type <type of old evidence> ~ new predicate
                -> TcS (StopOrContinue CtEvidence)
-- Returns Just new_ev iff either (i)  'co' is reflexivity
--                             or (ii) 'co' is not reflexivity, and 'new_pred' not cached
-- In either case, there is nothing new to do with new_ev
{-
     rewriteEvidence old_ev new_pred co
Main purpose: create new evidence for new_pred;
              unless new_pred is cached already
* Returns a new_ev : new_pred, with same wanted/given flag as old_ev
* If old_ev was wanted, create a binding for old_ev, in terms of new_ev
* If old_ev was given, AND not cached, create a binding for new_ev, in terms of old_ev
* Returns Nothing if new_ev is already cached

        Old evidence    New predicate is               Return new evidence
        flavour                                        of same flavor
        -------------------------------------------------------------------
        Wanted          Already solved or in inert     Nothing
                        Not                            Just new_evidence

        Given           Already in inert               Nothing
                        Not                            Just new_evidence

Note [Rewriting with Refl]
~~~~~~~~~~~~~~~~~~~~~~~~~~
If the coercion is just reflexivity then you may re-use the same
variable.  But be careful!  Although the coercion is Refl, new_pred
may reflect the result of unification alpha := ty, so new_pred might
not _look_ the same as old_pred, and it's vital to proceed from now on
using new_pred.

The rewriter preserves type synonyms, so they should appear in new_pred
as well as in old_pred; that is important for good error messages.

If we are rewriting with Refl, then there are no new rewriters to add to
the rewriter set. We check this with an assertion.
 -}


rewriteEvidence rewriters old_ev (Reduction co new_pred)
  | isReflCo co -- See Note [Rewriting with Refl]
  = assert (isEmptyRewriterSet rewriters) $
    continueWith (setCtEvPredType old_ev new_pred)

rewriteEvidence rewriters ev@(CtGiven { ctev_evar = old_evar, ctev_loc = loc })
                (Reduction co new_pred)
  = assert (isEmptyRewriterSet rewriters) $ -- this is a Given, not a wanted
    do { new_ev <- newGivenEvVar loc (new_pred, new_tm)
       ; continueWith new_ev }
  where
    -- mkEvCast optimises ReflCo
    new_tm = mkEvCast (evId old_evar)
                (downgradeRole Representational (ctEvRole ev) co)

rewriteEvidence new_rewriters
                ev@(CtWanted { ctev_dest = dest
                             , ctev_loc = loc
                             , ctev_rewriters = rewriters })
                (Reduction co new_pred)
  = do { mb_new_ev <- newWanted loc rewriters' new_pred
       ; massert (coercionRole co == ctEvRole ev)
       ; setWantedEvTerm dest
            (mkEvCast (getEvExpr mb_new_ev)
                      (downgradeRole Representational (ctEvRole ev) (mkSymCo co)))
       ; case mb_new_ev of
            Fresh  new_ev -> continueWith new_ev
            Cached _      -> stopWith ev "Cached wanted" }
  where
    rewriters' = rewriters S.<> new_rewriters


rewriteEqEvidence :: RewriterSet        -- New rewriters
                                        -- See GHC.Tc.Types.Constraint
                                        -- Note [Wanteds rewrite Wanteds]
                  -> CtEvidence         -- Old evidence :: olhs ~ orhs (not swapped)
                                        --              or orhs ~ olhs (swapped)
                  -> SwapFlag
                  -> Reduction          -- lhs_co :: olhs ~ nlhs
                  -> Reduction          -- rhs_co :: orhs ~ nrhs
                  -> TcS CtEvidence     -- Of type nlhs ~ nrhs
-- With reductions (Reduction lhs_co nlhs) (Reduction rhs_co nrhs),
-- rewriteEqEvidence yields, for a given equality (Given g olhs orhs):
-- If not swapped
--      g1 : nlhs ~ nrhs = sym lhs_co ; g ; rhs_co
-- If swapped
--      g1 : nlhs ~ nrhs = sym lhs_co ; Sym g ; rhs_co
--
-- For a wanted equality (Wanted w), we do the dual thing:
-- New  w1 : nlhs ~ nrhs
-- If not swapped
--      w : olhs ~ orhs = lhs_co ; w1 ; sym rhs_co
-- If swapped
--      w : orhs ~ olhs = rhs_co ; sym w1 ; sym lhs_co
--
-- It's all a form of rewriteEvidence, specialised for equalities
rewriteEqEvidence new_rewriters old_ev swapped (Reduction lhs_co nlhs) (Reduction rhs_co nrhs)
  | NotSwapped <- swapped
  , isReflCo lhs_co      -- See Note [Rewriting with Refl]
  , isReflCo rhs_co
  = return (setCtEvPredType old_ev new_pred)

  | CtGiven { ctev_evar = old_evar } <- old_ev
  = do { let new_tm = evCoercion ( mkSymCo lhs_co
                                  `mkTransCo` maybeSymCo swapped (mkCoVarCo old_evar)
                                  `mkTransCo` rhs_co)
       ; newGivenEvVar loc (new_pred, new_tm) }

  | CtWanted { ctev_dest = dest
             , ctev_rewriters = rewriters } <- old_ev
  , let rewriters' = rewriters S.<> new_rewriters
  = do { (new_ev, hole_co) <- newWantedEq loc rewriters'
                                          (ctEvRole old_ev) nlhs nrhs
       ; let co = maybeSymCo swapped $
                  lhs_co
                  `mkTransCo` hole_co
                  `mkTransCo` mkSymCo rhs_co
       ; setWantedEq dest co
       ; traceTcS "rewriteEqEvidence" (vcat [ ppr old_ev
                                            , ppr nlhs
                                            , ppr nrhs
                                            , ppr co
                                            , ppr new_rewriters ])
       ; return new_ev }

#if __GLASGOW_HASKELL__ <= 810
  | otherwise
  = panic "rewriteEvidence"
#endif
  where
    new_pred = mkTcEqPredLikeEv old_ev nlhs nrhs
    loc      = ctEvLoc old_ev

{-
************************************************************************
*                                                                      *
              Unification
*                                                                      *
************************************************************************

Note [unifyWanted]
~~~~~~~~~~~~~~~~~~
When decomposing equalities we often create new wanted constraints for
(s ~ t).  But what if s=t?  Then it'd be faster to return Refl right away.

Rather than making an equality test (which traverses the structure of the
type, perhaps fruitlessly), unifyWanted traverses the common structure, and
bales out when it finds a difference by creating a new Wanted constraint.
But where it succeeds in finding common structure, it just builds a coercion
to reflect it.
-}

unifyWanted :: RewriterSet -> CtLoc
            -> Role -> TcType -> TcType -> TcS Coercion
-- Return coercion witnessing the equality of the two types,
-- emitting new work equalities where necessary to achieve that
-- Very good short-cut when the two types are equal, or nearly so
-- See Note [unifyWanted]
-- The returned coercion's role matches the input parameter
unifyWanted rewriters loc Phantom ty1 ty2
  = do { kind_co <- unifyWanted rewriters loc Nominal (typeKind ty1) (typeKind ty2)
       ; return (mkPhantomCo kind_co ty1 ty2) }

unifyWanted rewriters loc role orig_ty1 orig_ty2
  = go orig_ty1 orig_ty2
  where
    go ty1 ty2 | Just ty1' <- coreView ty1 = go ty1' ty2
    go ty1 ty2 | Just ty2' <- coreView ty2 = go ty1 ty2'

    go (FunTy af1 w1 s1 t1) (FunTy af2 w2 s2 t2)
      | af1 == af2    -- Important!  See #21530
      = do { co_s <- unifyWanted rewriters loc role s1 s2
           ; co_t <- unifyWanted rewriters loc role t1 t2
           ; co_w <- unifyWanted rewriters loc Nominal w1 w2
           ; return (mkNakedFunCo1 role af1 co_w co_s co_t) }

    go (TyConApp tc1 tys1) (TyConApp tc2 tys2)
      | tc1 == tc2, tys1 `equalLength` tys2
      , isInjectiveTyCon tc1 role -- don't look under newtypes at Rep equality
      = do { cos <- zipWith3M (unifyWanted rewriters loc)
                              (tyConRoleListX role tc1) tys1 tys2
           ; return (mkTyConAppCo role tc1 cos) }

    go ty1@(TyVarTy tv) ty2
      = do { mb_ty <- isFilledMetaTyVar_maybe tv
           ; case mb_ty of
                Just ty1' -> go ty1' ty2
                Nothing   -> bale_out ty1 ty2}
    go ty1 ty2@(TyVarTy tv)
      = do { mb_ty <- isFilledMetaTyVar_maybe tv
           ; case mb_ty of
                Just ty2' -> go ty1 ty2'
                Nothing   -> bale_out ty1 ty2 }

    go ty1@(CoercionTy {}) (CoercionTy {})
      = return (mkReflCo role ty1) -- we just don't care about coercions!

    go ty1 ty2 = bale_out ty1 ty2

    bale_out ty1 ty2
       | ty1 `tcEqType` ty2 = return (mkReflCo role ty1)
        -- Check for equality; e.g. a ~ a, or (m a) ~ (m a)
       | otherwise = emitNewWantedEq loc rewriters role orig_ty1 orig_ty2


{-
Note [Decomposing Dependent TyCons and Processing Wanted Equalities]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When we decompose a dependent tycon we obtain a list of
mixed wanted type and kind equalities. Ideally we want
all the kind equalities to get solved first so that we avoid
generating duplicate kind equalities

For example, consider decomposing a TyCon equality

    (0) [W] T k_fresh (t1::k_fresh) ~ T k1 (t2::k_fresh)

This gives rise to 2 equalities in the solver worklist

    (1) [W] k_fresh ~ k1
    (2) [W] t1::k_fresh ~ t2::k1

The solver worklist is processed in LIFO order:
see GHC.Tc.Solver.InertSet.selectWorkItem.
i.e. (2) is processed _before_ (1). Now, while solving (2)
we would call `canEqCanLHSHetero` and that would emit a
wanted kind equality

    (3) [W] k_fresh ~ k1

But (3) is exactly the same as (1)!

To avoid such duplicate wanted constraints from being added to the worklist,
we ensure that (2) is processed before (1). Since we are processing
the worklist in a LIFO ordering, we do it by emitting (1) before (2).
This is exactly what we do in `unifyWanteds`.

NB: This ordering is not needed when we decompose FunTyCons as they are not dependently typed
-}

-- NB: Length of [CtLoc] and [Roles] may be infinite
-- but list of RHS [TcType] and LHS [TcType] is finite and both are of equal length
unifyWanteds :: RewriterSet -> [CtLoc] -> [Role]
             -> [TcType] -- List of RHS types
             -> [TcType] -- List of LHS types
             -> TcS [Coercion]
unifyWanteds rewriters ctlocs roles rhss lhss = unify_wanteds rewriters $ zip4 ctlocs roles rhss lhss
  where
    -- Order is important here
    -- See Note [Decomposing Dependent TyCons and Processing Wanted Equalities]
    unify_wanteds _ [] = return []
    unify_wanteds rewriters ((new_loc, tc_role, ty1, ty2) : rest)
       = do { cos <- unify_wanteds rewriters rest
            ; co  <- unifyWanted rewriters new_loc tc_role ty1 ty2
            ; return (co:cos) }
