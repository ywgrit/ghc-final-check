{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}

{-# OPTIONS_GHC -Wno-orphans #-}

-- | Monadic definitions for the constraint solver
module GHC.Tc.Solver.Monad (

    -- The TcS monad
    TcS, runTcS, runTcSEarlyAbort, runTcSWithEvBinds, runTcSInerts,
    failTcS, warnTcS, addErrTcS, wrapTcS, ctLocWarnTcS,
    runTcSEqualities,
    nestTcS, nestImplicTcS, setEvBindsTcS,
    emitImplicationTcS, emitTvImplicationTcS,

    selectNextWorkItem,
    getWorkList,
    updWorkListTcS,
    pushLevelNoWorkList,

    runTcPluginTcS, recordUsedGREs,
    matchGlobalInst, TcM.ClsInstResult(..),

    QCInst(..),

    -- Tracing etc
    panicTcS, traceTcS,
    traceFireTcS, bumpStepCountTcS, csTraceTcS,
    wrapErrTcS, wrapWarnTcS,
    resetUnificationFlag, setUnificationFlag,

    -- Evidence creation and transformation
    MaybeNew(..), freshGoals, isFresh, getEvExpr,

    newTcEvBinds, newNoTcEvBinds,
    newWantedEq, emitNewWantedEq,
    newWanted,
    newWantedNC, newWantedEvVarNC,
    newBoundEvVarId,
    unifyTyVar, reportUnifications, touchabilityTest, TouchabilityTestResult(..),
    setEvBind, setWantedEq,
    setWantedEvTerm, setEvBindIfWanted,
    newEvVar, newGivenEvVar, newGivenEvVars,
    checkReductionDepth,
    getSolvedDicts, setSolvedDicts,

    getInstEnvs, getFamInstEnvs,                -- Getting the environments
    getTopEnv, getGblEnv, getLclEnv, setLclEnv,
    getTcEvBindsVar, getTcLevel,
    getTcEvTyCoVars, getTcEvBindsMap, setTcEvBindsMap,
    tcLookupClass, tcLookupId,

    -- Inerts
    updInertTcS, updInertCans, updInertDicts, updInertIrreds,
    getHasGivenEqs, setInertCans,
    getInertEqs, getInertCans, getInertGivens,
    getInertInsols, getInnermostGivenEqLevel,
    getTcSInerts, setTcSInerts,
    getUnsolvedInerts,
    removeInertCts, getPendingGivenScs,
    addInertCan, insertFunEq, addInertForAll,
    emitWorkNC, emitWork,
    lookupInertDict,

    -- The Model
    kickOutAfterUnification,

    -- Inert Safe Haskell safe-overlap failures
    addInertSafehask, insertSafeOverlapFailureTcS, updInertSafehask,
    getSafeOverlapFailures,

    -- Inert solved dictionaries
    addSolvedDict, lookupSolvedDict,

    -- Irreds
    foldIrreds,

    -- The family application cache
    lookupFamAppInert, lookupFamAppCache, extendFamAppCache,
    pprKicked,

    instDFunType,                              -- Instantiation

    -- MetaTyVars
    newFlexiTcSTy, instFlexiX,
    cloneMetaTyVar,
    tcInstSkolTyVarsX,

    TcLevel,
    isFilledMetaTyVar_maybe, isFilledMetaTyVar,
    zonkTyCoVarsAndFV, zonkTcType, zonkTcTypes, zonkTcTyVar, zonkCo,
    zonkTyCoVarsAndFVList,
    zonkSimples, zonkWC,
    zonkTyCoVarKind,

    -- References
    newTcRef, readTcRef, writeTcRef, updTcRef,

    -- Misc
    getDefaultInfo, getDynFlags, getGlobalRdrEnvTcS,
    matchFam, matchFamTcM,
    checkWellStagedDFun,
    pprEq,                                   -- Smaller utils, re-exported from TcM
                                             -- TODO (DV): these are only really used in the
                                             -- instance matcher in GHC.Tc.Solver. I am wondering
                                             -- if the whole instance matcher simply belongs
                                             -- here

    breakTyEqCycle_maybe, rewriterView
) where

import GHC.Prelude

import GHC.Driver.Env

import qualified GHC.Tc.Utils.Instantiate as TcM
import GHC.Core.InstEnv
import GHC.Tc.Instance.Family as FamInst
import GHC.Core.FamInstEnv

import qualified GHC.Tc.Utils.Monad    as TcM
import qualified GHC.Tc.Utils.TcMType  as TcM
import qualified GHC.Tc.Instance.Class as TcM( matchGlobalInst, ClsInstResult(..) )
import qualified GHC.Tc.Utils.Env      as TcM
       ( checkWellStaged, tcGetDefaultTys, tcLookupClass, tcLookupId, topIdLvl
       , tcInitTidyEnv )

import GHC.Driver.Session

import GHC.Tc.Instance.Class( InstanceWhat(..), safeOverlap, instanceReturnsDictCon )
import GHC.Tc.Utils.TcType
import GHC.Tc.Solver.Types
import GHC.Tc.Solver.InertSet
import GHC.Tc.Types.Evidence
import GHC.Tc.Errors.Types

import GHC.Core.Type
import qualified GHC.Core.TyCo.Rep as Rep  -- this needs to be used only very locally
import GHC.Core.Coercion
import GHC.Core.Reduction
import GHC.Core.Class
import GHC.Core.TyCon

import GHC.Types.Error ( mkPlainError, noHints )
import GHC.Types.Name
import GHC.Types.TyThing
import GHC.Types.Name.Reader

import GHC.Unit.Module ( HasModule, getModule, extractModule )
import qualified GHC.Rename.Env as TcM
import GHC.Types.Var
import GHC.Types.Var.Env
import GHC.Types.Var.Set
import GHC.Utils.Outputable
import GHC.Utils.Panic
import GHC.Utils.Logger
import GHC.Utils.Misc (HasDebugCallStack)
import GHC.Data.Bag as Bag
import GHC.Types.Unique.Supply
import GHC.Tc.Types
import GHC.Tc.Types.Origin
import GHC.Tc.Types.Constraint
import GHC.Tc.Utils.Unify
import GHC.Core.Predicate
import GHC.Types.Unique.Set (nonDetEltsUniqSet)

import Control.Monad
import GHC.Utils.Monad
import Data.IORef
import GHC.Exts (oneShot)
import Data.List ( mapAccumL, partition )
import Data.Foldable

#if defined(DEBUG)
import GHC.Data.Graph.Directed
#endif

{- *********************************************************************
*                                                                      *
                   Inert instances: inert_insts
*                                                                      *
********************************************************************* -}

addInertForAll :: QCInst -> TcS ()
-- Add a local Given instance, typically arising from a type signature
addInertForAll new_qci
  = do { ics  <- getInertCans
       ; ics1 <- add_qci ics

       -- Update given equalities. C.f updateGivenEqs
       ; tclvl <- getTcLevel
       ; let pred         = qci_pred new_qci
             not_equality = isClassPred pred && not (isEqPred pred)
                  -- True <=> definitely not an equality
                  -- A qci_pred like (f a) might be an equality

             ics2 | not_equality = ics1
                  | otherwise    = ics1 { inert_given_eq_lvl = tclvl
                                        , inert_given_eqs    = True }

       ; setInertCans ics2 }
  where
    add_qci :: InertCans -> TcS InertCans
    -- See Note [Do not add duplicate quantified instances]
    add_qci ics@(IC { inert_insts = qcis })
      | any same_qci qcis
      = do { traceTcS "skipping duplicate quantified instance" (ppr new_qci)
           ; return ics }

      | otherwise
      = do { traceTcS "adding new inert quantified instance" (ppr new_qci)
           ; return (ics { inert_insts = new_qci : qcis }) }

    same_qci old_qci = tcEqType (ctEvPred (qci_ev old_qci))
                                (ctEvPred (qci_ev new_qci))

{- Note [Do not add duplicate quantified instances]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
As an optimisation, we avoid adding duplicate quantified instances to the
inert set; we use a simple duplicate check using tcEqType for simplicity,
even though it doesn't account for superficial differences, e.g. it will count
the following two constraints as different (#22223):

  - forall a b. C a b
  - forall b a. C a b

The main logic that allows us to pick local instances, even in the presence of
duplicates, is explained in Note [Use only the best matching quantified constraint]
in GHC.Tc.Solver.Interact.
-}

{- *********************************************************************
*                                                                      *
                  Adding an inert
*                                                                      *
************************************************************************

Note [Adding an equality to the InertCans]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When adding an equality to the inerts:

* Kick out any constraints that can be rewritten by the thing
  we are adding.  Done by kickOutRewritable.

* Note that unifying a:=ty, is like adding [G] a~ty; just use
  kickOutRewritable with Nominal, Given.  See kickOutAfterUnification.

Note [Kick out existing binding for implicit parameter]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Suppose we have (typecheck/should_compile/ImplicitParamFDs)
  flub :: (?x :: Int) => (Int, Integer)
  flub = (?x, let ?x = 5 in ?x)
When we are checking the last ?x occurrence, we guess its type
to be a fresh unification variable alpha and emit an (IP "x" alpha)
constraint. But the given (?x :: Int) has been translated to an
IP "x" Int constraint, which has a functional dependency from the
name to the type. So fundep interaction tells us that alpha ~ Int,
and we get a type error. This is bad.

Instead, we wish to excise any old given for an IP when adding a
new one. We also must make sure not to float out
any IP constraints outside an implication that binds an IP of
the same name; see GHC.Tc.Solver.floatConstraints.
-}

addInertCan :: Ct -> TcS ()
-- Precondition: item /is/ canonical
-- See Note [Adding an equality to the InertCans]
addInertCan ct =
    do { traceTcS "addInertCan {" $
         text "Trying to insert new inert item:" <+> ppr ct
       ; mkTcS (\TcSEnv{tcs_abort_on_insoluble=abort_flag} ->
                 when (abort_flag && insolubleEqCt ct) TcM.failM)
       ; ics <- getInertCans
       ; ics <- maybeKickOut ics ct
       ; tclvl <- getTcLevel
       ; setInertCans (addInertItem tclvl ics ct)

       ; traceTcS "addInertCan }" $ empty }

maybeKickOut :: InertCans -> Ct -> TcS InertCans
-- For a CEqCan, kick out any inert that can be rewritten by the CEqCan
maybeKickOut ics ct
  | CEqCan { cc_lhs = lhs, cc_ev = ev, cc_eq_rel = eq_rel } <- ct
  = do { (_, ics') <- kickOutRewritable (ctEvFlavour ev, eq_rel) lhs ics
       ; return ics' }

     -- See [Kick out existing binding for implicit parameter]
  | isGivenCt ct
  , CDictCan { cc_class = cls, cc_tyargs = [ip_name_strty, _ip_ty] } <- ct
  , isIPClass cls
  , Just ip_name <- isStrLitTy ip_name_strty
     -- Would this be more efficient if we used findDictsByClass and then delDict?
  = let dict_map = inert_dicts ics
        dict_map' = filterDicts doesn't_match_ip_name dict_map

        doesn't_match_ip_name :: Ct -> Bool
        doesn't_match_ip_name ct
          | Just (inert_ip_name, _inert_ip_ty) <- isIPPred_maybe (ctPred ct)
          = inert_ip_name /= ip_name

          | otherwise
          = True

    in
    return (ics { inert_dicts = dict_map' })

  | otherwise
  = return ics

-----------------------------------------
kickOutRewritable  :: CtFlavourRole  -- Flavour/role of the equality that
                                      -- is being added to the inert set
                   -> CanEqLHS        -- The new equality is lhs ~ ty
                   -> InertCans
                   -> TcS (Int, InertCans)
kickOutRewritable new_fr new_lhs ics
  = do { let (kicked_out, ics') = kickOutRewritableLHS new_fr new_lhs ics
             n_kicked = workListSize kicked_out

       ; unless (n_kicked == 0) $
         do { updWorkListTcS (appendWorkList kicked_out)

              -- The famapp-cache contains Given evidence from the inert set.
              -- If we're kicking out Givens, we need to remove this evidence
              -- from the cache, too.
            ; let kicked_given_ev_vars =
                    [ ev_var | ct <- wl_eqs kicked_out
                             , CtGiven { ctev_evar = ev_var } <- [ctEvidence ct] ]
            ; when (new_fr `eqCanRewriteFR` (Given, NomEq) &&
                   -- if this isn't true, no use looking through the constraints
                    not (null kicked_given_ev_vars)) $
              do { traceTcS "Given(s) have been kicked out; drop from famapp-cache"
                            (ppr kicked_given_ev_vars)
                 ; dropFromFamAppCache (mkVarSet kicked_given_ev_vars) }

            ; csTraceTcS $
              hang (text "Kick out, lhs =" <+> ppr new_lhs)
                 2 (vcat [ text "n-kicked =" <+> int n_kicked
                         , text "kicked_out =" <+> ppr kicked_out
                         , text "Residual inerts =" <+> ppr ics' ]) }

       ; return (n_kicked, ics') }

kickOutAfterUnification :: TcTyVar -> TcS Int
kickOutAfterUnification new_tv
  = do { ics <- getInertCans
       ; (n_kicked, ics2) <- kickOutRewritable (Given,NomEq)
                                                 (TyVarLHS new_tv) ics
                     -- Given because the tv := xi is given; NomEq because
                     -- only nominal equalities are solved by unification

       ; setInertCans ics2
       ; return n_kicked }

-- See Wrinkle (2) in Note [Equalities with incompatible kinds] in GHC.Tc.Solver.Canonical
-- It's possible that this could just go ahead and unify, but could there be occurs-check
-- problems? Seems simpler just to kick out.
kickOutAfterFillingCoercionHole :: CoercionHole -> TcS ()
kickOutAfterFillingCoercionHole hole
  = do { ics <- getInertCans
       ; let (kicked_out, ics') = kick_out ics
             n_kicked           = workListSize kicked_out

       ; unless (n_kicked == 0) $
         do { updWorkListTcS (appendWorkList kicked_out)
            ; csTraceTcS $
              hang (text "Kick out, hole =" <+> ppr hole)
                 2 (vcat [ text "n-kicked =" <+> int n_kicked
                         , text "kicked_out =" <+> ppr kicked_out
                         , text "Residual inerts =" <+> ppr ics' ]) }

       ; setInertCans ics' }
  where
    kick_out :: InertCans -> (WorkList, InertCans)
    kick_out ics@(IC { inert_eqs = eqs, inert_funeqs = funeqs })
      = (kicked_out, ics { inert_eqs = eqs_to_keep, inert_funeqs = funeqs_to_keep })
      where
        (eqs_to_kick, eqs_to_keep)       = partitionInertEqs kick_ct eqs
        (funeqs_to_kick, funeqs_to_keep) = partitionFunEqs kick_ct funeqs
        kicked_out = extendWorkListCts (eqs_to_kick ++ funeqs_to_kick) emptyWorkList

    kick_ct :: Ct -> Bool
         -- True: kick out; False: keep.
    kick_ct (CEqCan { cc_rhs = rhs, cc_ev = ctev })
      = isWanted ctev &&    -- optimisation: givens don't have coercion holes anyway
        rhs `hasThisCoercionHoleTy` hole
    kick_ct other = pprPanic "kick_ct (coercion hole)" (ppr other)

--------------
addInertSafehask :: InertCans -> Ct -> InertCans
addInertSafehask ics item@(CDictCan { cc_class = cls, cc_tyargs = tys })
  = ics { inert_safehask = addDict (inert_dicts ics) cls tys item }

addInertSafehask _ item
  = pprPanic "addInertSafehask: can't happen! Inserting " $ ppr item

insertSafeOverlapFailureTcS :: InstanceWhat -> Ct -> TcS ()
-- See Note [Safe Haskell Overlapping Instances Implementation] in GHC.Tc.Solver
insertSafeOverlapFailureTcS what item
  | safeOverlap what = return ()
  | otherwise        = updInertCans (\ics -> addInertSafehask ics item)

getSafeOverlapFailures :: TcS Cts
-- See Note [Safe Haskell Overlapping Instances Implementation] in GHC.Tc.Solver
getSafeOverlapFailures
 = do { IC { inert_safehask = safehask } <- getInertCans
      ; return $ foldDicts consCts safehask emptyCts }

--------------
addSolvedDict :: InstanceWhat -> CtEvidence -> Class -> [Type] -> TcS ()
-- Conditionally add a new item in the solved set of the monad
-- See Note [Solved dictionaries] in GHC.Tc.Solver.InertSet
addSolvedDict what item cls tys
  | isWanted item
  , instanceReturnsDictCon what
  = do { traceTcS "updSolvedSetTcs:" $ ppr item
       ; updInertTcS $ \ ics ->
             ics { inert_solved_dicts = addDict (inert_solved_dicts ics) cls tys item } }
  | otherwise
  = return ()

getSolvedDicts :: TcS (DictMap CtEvidence)
getSolvedDicts = do { ics <- getTcSInerts; return (inert_solved_dicts ics) }

setSolvedDicts :: DictMap CtEvidence -> TcS ()
setSolvedDicts solved_dicts
  = updInertTcS $ \ ics ->
    ics { inert_solved_dicts = solved_dicts }

{- *********************************************************************
*                                                                      *
                  Other inert-set operations
*                                                                      *
********************************************************************* -}

updInertTcS :: (InertSet -> InertSet) -> TcS ()
-- Modify the inert set with the supplied function
updInertTcS upd_fn
  = do { is_var <- getTcSInertsRef
       ; wrapTcS (do { curr_inert <- TcM.readTcRef is_var
                     ; TcM.writeTcRef is_var (upd_fn curr_inert) }) }

getInertCans :: TcS InertCans
getInertCans = do { inerts <- getTcSInerts; return (inert_cans inerts) }

setInertCans :: InertCans -> TcS ()
setInertCans ics = updInertTcS $ \ inerts -> inerts { inert_cans = ics }

updRetInertCans :: (InertCans -> (a, InertCans)) -> TcS a
-- Modify the inert set with the supplied function
updRetInertCans upd_fn
  = do { is_var <- getTcSInertsRef
       ; wrapTcS (do { inerts <- TcM.readTcRef is_var
                     ; let (res, cans') = upd_fn (inert_cans inerts)
                     ; TcM.writeTcRef is_var (inerts { inert_cans = cans' })
                     ; return res }) }

updInertCans :: (InertCans -> InertCans) -> TcS ()
-- Modify the inert set with the supplied function
updInertCans upd_fn
  = updInertTcS $ \ inerts -> inerts { inert_cans = upd_fn (inert_cans inerts) }

updInertDicts :: (DictMap Ct -> DictMap Ct) -> TcS ()
-- Modify the inert set with the supplied function
updInertDicts upd_fn
  = updInertCans $ \ ics -> ics { inert_dicts = upd_fn (inert_dicts ics) }

updInertSafehask :: (DictMap Ct -> DictMap Ct) -> TcS ()
-- Modify the inert set with the supplied function
updInertSafehask upd_fn
  = updInertCans $ \ ics -> ics { inert_safehask = upd_fn (inert_safehask ics) }

updInertIrreds :: (Cts -> Cts) -> TcS ()
-- Modify the inert set with the supplied function
updInertIrreds upd_fn
  = updInertCans $ \ ics -> ics { inert_irreds = upd_fn (inert_irreds ics) }

getInertEqs :: TcS InertEqs
getInertEqs = do { inert <- getInertCans; return (inert_eqs inert) }

getInnermostGivenEqLevel :: TcS TcLevel
getInnermostGivenEqLevel = do { inert <- getInertCans
                              ; return (inert_given_eq_lvl inert) }

getInertInsols :: TcS Cts
-- Returns insoluble equality constraints and TypeError constraints,
-- specifically including Givens.
--
-- Note that this function only inspects irreducible constraints;
-- a DictCan constraint such as 'Eq (TypeError msg)' is not
-- considered to be an insoluble constraint by this function.
--
-- See Note [Pattern match warnings with insoluble Givens] in GHC.Tc.Solver.
getInertInsols = do { inert <- getInertCans
                    ; return $ filterBag insolubleCt (inert_irreds inert) }

getInertGivens :: TcS [Ct]
-- Returns the Given constraints in the inert set
getInertGivens
  = do { inerts <- getInertCans
       ; let all_cts = foldIrreds (:) (inert_irreds inerts)
                     $ foldDicts (:) (inert_dicts inerts)
                     $ foldFunEqs (++) (inert_funeqs inerts)
                     $ foldDVarEnv (++) [] (inert_eqs inerts)
       ; return (filter isGivenCt all_cts) }

getPendingGivenScs :: TcS [Ct]
-- Find all inert Given dictionaries, or quantified constraints,
--     whose cc_pend_sc flag is True
--     and that belong to the current level
-- Set their cc_pend_sc flag to False in the inert set, and return that Ct
getPendingGivenScs = do { lvl <- getTcLevel
                        ; updRetInertCans (get_sc_pending lvl) }

get_sc_pending :: TcLevel -> InertCans -> ([Ct], InertCans)
get_sc_pending this_lvl ic@(IC { inert_dicts = dicts, inert_insts = insts })
  = assertPpr (all isGivenCt sc_pending) (ppr sc_pending)
       -- When getPendingScDics is called,
       -- there are never any Wanteds in the inert set
    (sc_pending, ic { inert_dicts = dicts', inert_insts = insts' })
  where
    sc_pending = sc_pend_insts ++ sc_pend_dicts

    sc_pend_dicts = foldDicts get_pending dicts []
    dicts' = foldr add dicts sc_pend_dicts

    (sc_pend_insts, insts') = mapAccumL get_pending_inst [] insts

    get_pending :: Ct -> [Ct] -> [Ct]  -- Get dicts with cc_pend_sc = True
                                       -- but flipping the flag
    get_pending dict dicts
        | Just dict' <- pendingScDict_maybe dict
        , belongs_to_this_level (ctEvidence dict)
        = dict' : dicts
        | otherwise
        = dicts

    add :: Ct -> DictMap Ct -> DictMap Ct
    add ct@(CDictCan { cc_class = cls, cc_tyargs = tys }) dicts
        = addDict dicts cls tys ct
    add ct _ = pprPanic "getPendingScDicts" (ppr ct)

    get_pending_inst :: [Ct] -> QCInst -> ([Ct], QCInst)
    get_pending_inst cts qci@(QCI { qci_ev = ev })
       | Just qci' <- pendingScInst_maybe qci
       , belongs_to_this_level ev
       = (CQuantCan qci' : cts, qci')
       | otherwise
       = (cts, qci)

    belongs_to_this_level ev = ctLocLevel (ctEvLoc ev) == this_lvl
    -- We only want Givens from this level; see (3a) in
    -- Note [The superclass story] in GHC.Tc.Solver.Canonical

getUnsolvedInerts :: TcS ( Bag Implication
                         , Cts )   -- All simple constraints
-- Return all the unsolved [Wanted] constraints
--
-- Post-condition: the returned simple constraints are all fully zonked
--                     (because they come from the inert set)
--                 the unsolved implics may not be
getUnsolvedInerts
 = do { IC { inert_eqs     = tv_eqs
           , inert_funeqs  = fun_eqs
           , inert_irreds  = irreds
           , inert_dicts   = idicts
           } <- getInertCans

      ; let unsolved_tv_eqs  = foldTyEqs add_if_unsolved tv_eqs emptyCts
            unsolved_fun_eqs = foldFunEqs add_if_unsolveds fun_eqs emptyCts
            unsolved_irreds  = Bag.filterBag isWantedCt irreds
            unsolved_dicts   = foldDicts add_if_unsolved idicts emptyCts
            unsolved_others  = unionManyBags [ unsolved_irreds
                                             , unsolved_dicts ]

      ; implics <- getWorkListImplics

      ; traceTcS "getUnsolvedInerts" $
        vcat [ text " tv eqs =" <+> ppr unsolved_tv_eqs
             , text "fun eqs =" <+> ppr unsolved_fun_eqs
             , text "others =" <+> ppr unsolved_others
             , text "implics =" <+> ppr implics ]

      ; return ( implics, unsolved_tv_eqs `unionBags`
                          unsolved_fun_eqs `unionBags`
                          unsolved_others) }
  where
    add_if_unsolved :: Ct -> Cts -> Cts
    add_if_unsolved ct cts | isWantedCt ct = ct `consCts` cts
                           | otherwise     = cts

    add_if_unsolveds :: EqualCtList -> Cts -> Cts
    add_if_unsolveds new_cts old_cts = foldr add_if_unsolved old_cts new_cts

getHasGivenEqs :: TcLevel           -- TcLevel of this implication
               -> TcS ( HasGivenEqs -- are there Given equalities?
                      , Cts )       -- Insoluble equalities arising from givens
-- See Note [Tracking Given equalities] in GHC.Tc.Solver.InertSet
getHasGivenEqs tclvl
  = do { inerts@(IC { inert_irreds       = irreds
                    , inert_given_eqs    = given_eqs
                    , inert_given_eq_lvl = ge_lvl })
              <- getInertCans
       ; let given_insols = filterBag insoluble_given_equality irreds
                      -- Specifically includes ones that originated in some
                      -- outer context but were refined to an insoluble by
                      -- a local equality; so no level-check needed

             -- See Note [HasGivenEqs] in GHC.Tc.Types.Constraint, and
             -- Note [Tracking Given equalities] in GHC.Tc.Solver.InertSet
             has_ge | ge_lvl == tclvl = MaybeGivenEqs
                    | given_eqs       = LocalGivenEqs
                    | otherwise       = NoGivenEqs

       ; traceTcS "getHasGivenEqs" $
         vcat [ text "given_eqs:" <+> ppr given_eqs
              , text "ge_lvl:" <+> ppr ge_lvl
              , text "ambient level:" <+> ppr tclvl
              , text "Inerts:" <+> ppr inerts
              , text "Insols:" <+> ppr given_insols]
       ; return (has_ge, given_insols) }
  where
    insoluble_given_equality ct
       = insolubleEqCt ct && isGivenCt ct

removeInertCts :: [Ct] -> InertCans -> InertCans
-- ^ Remove inert constraints from the 'InertCans', for use when a
-- typechecker plugin wishes to discard a given.
removeInertCts cts icans = foldl' removeInertCt icans cts

removeInertCt :: InertCans -> Ct -> InertCans
removeInertCt is ct =
  case ct of

    CDictCan  { cc_class = cl, cc_tyargs = tys } ->
      is { inert_dicts = delDict (inert_dicts is) cl tys }

    CEqCan    { cc_lhs  = lhs, cc_rhs = rhs } -> delEq is lhs rhs

    CIrredCan {}     -> is { inert_irreds = filterBag (not . eqCt ct) $ inert_irreds is }

    CQuantCan {}     -> panic "removeInertCt: CQuantCan"
    CNonCanonical {} -> panic "removeInertCt: CNonCanonical"

eqCt :: Ct -> Ct -> Bool
-- Equality via ctEvId
eqCt c c' = ctEvId c == ctEvId c'

-- | Looks up a family application in the inerts.
lookupFamAppInert :: (CtFlavourRole -> Bool)  -- can it rewrite the target?
                  -> TyCon -> [Type] -> TcS (Maybe (Reduction, CtFlavourRole))
lookupFamAppInert rewrite_pred fam_tc tys
  = do { IS { inert_cans = IC { inert_funeqs = inert_funeqs } } <- getTcSInerts
       ; return (lookup_inerts inert_funeqs) }
  where
    lookup_inerts inert_funeqs
      | Just ecl <- findFunEq inert_funeqs fam_tc tys
      , Just (CEqCan { cc_ev = ctev, cc_rhs = rhs })
          <- find (rewrite_pred . ctFlavourRole) ecl
      = Just (mkReduction (ctEvCoercion ctev) rhs, ctEvFlavourRole ctev)
      | otherwise = Nothing

lookupInInerts :: CtLoc -> TcPredType -> TcS (Maybe CtEvidence)
-- Is this exact predicate type cached in the solved or canonicals of the InertSet?
lookupInInerts loc pty
  | ClassPred cls tys <- classifyPredType pty
  = do { inerts <- getTcSInerts
       ; let mb_solved = lookupSolvedDict inerts loc cls tys
             mb_inert  = fmap ctEvidence (lookupInertDict (inert_cans inerts) loc cls tys)
       ; return $ do -- Maybe monad
            found_ev <- mb_solved `mplus` mb_inert

            -- We're about to "solve" the wanted we're looking up, so we
            -- must make sure doing so wouldn't run afoul of
            -- Note [Solving superclass constraints] in GHC.Tc.TyCl.Instance.
            -- Forgetting this led to #20666.
            guard $ not (prohibitedSuperClassSolve (ctEvLoc found_ev) loc)

            return found_ev }
  | otherwise -- NB: No caching for equalities, IPs, holes, or errors
  = return Nothing

-- | Look up a dictionary inert.
lookupInertDict :: InertCans -> CtLoc -> Class -> [Type] -> Maybe Ct
lookupInertDict (IC { inert_dicts = dicts }) loc cls tys
  = case findDict dicts loc cls tys of
      Just ct -> Just ct
      _       -> Nothing

-- | Look up a solved inert.
lookupSolvedDict :: InertSet -> CtLoc -> Class -> [Type] -> Maybe CtEvidence
-- Returns just if exactly this predicate type exists in the solved.
lookupSolvedDict (IS { inert_solved_dicts = solved }) loc cls tys
  = case findDict solved loc cls tys of
      Just ev -> Just ev
      _       -> Nothing

---------------------------
lookupFamAppCache :: TyCon -> [Type] -> TcS (Maybe Reduction)
lookupFamAppCache fam_tc tys
  = do { IS { inert_famapp_cache = famapp_cache } <- getTcSInerts
       ; case findFunEq famapp_cache fam_tc tys of
           result@(Just redn) ->
             do { traceTcS "famapp_cache hit" (vcat [ ppr (mkTyConApp fam_tc tys)
                                                    , ppr redn ])
                ; return result }
           Nothing -> return Nothing }

extendFamAppCache :: TyCon -> [Type] -> Reduction -> TcS ()
-- NB: co :: rhs ~ F tys, to match expectations of rewriter
extendFamAppCache tc xi_args stuff@(Reduction _ ty)
  = do { dflags <- getDynFlags
       ; when (gopt Opt_FamAppCache dflags) $
    do { traceTcS "extendFamAppCache" (vcat [ ppr tc <+> ppr xi_args
                                            , ppr ty ])
       ; updInertTcS $ \ is@(IS { inert_famapp_cache = fc }) ->
            is { inert_famapp_cache = insertFunEq fc tc xi_args stuff } } }

-- Remove entries from the cache whose evidence mentions variables in the
-- supplied set
dropFromFamAppCache :: VarSet -> TcS ()
dropFromFamAppCache varset
  = do { inerts@(IS { inert_famapp_cache = famapp_cache }) <- getTcSInerts
       ; let filtered = filterTcAppMap check famapp_cache
       ; setTcSInerts $ inerts { inert_famapp_cache = filtered } }
  where
    check :: Reduction -> Bool
    check redn
      = not (anyFreeVarsOfCo (`elemVarSet` varset) $ reductionCoercion redn)

{- *********************************************************************
*                                                                      *
                   Irreds
*                                                                      *
********************************************************************* -}

foldIrreds :: (Ct -> b -> b) -> Cts -> b -> b
foldIrreds k irreds z = foldr k z irreds

{-
************************************************************************
*                                                                      *
*              The TcS solver monad                                    *
*                                                                      *
************************************************************************

Note [The TcS monad]
~~~~~~~~~~~~~~~~~~~~
The TcS monad is a weak form of the main Tc monad

All you can do is
    * fail
    * allocate new variables
    * fill in evidence variables

Filling in a dictionary evidence variable means to create a binding
for it, so TcS carries a mutable location where the binding can be
added.  This is initialised from the innermost implication constraint.
-}

data TcSEnv
  = TcSEnv {
      tcs_ev_binds    :: EvBindsVar,

      tcs_unified     :: IORef Int,
         -- The number of unification variables we have filled
         -- The important thing is whether it is non-zero

      tcs_unif_lvl  :: IORef (Maybe TcLevel),
         -- The Unification Level Flag
         -- Outermost level at which we have unified a meta tyvar
         -- Starts at Nothing, then (Just i), then (Just j) where j<i
         -- See Note [The Unification Level Flag]

      tcs_count     :: IORef Int, -- Global step count

      tcs_inerts    :: IORef InertSet, -- Current inert set

      -- Whether to throw an exception if we come across an insoluble constraint.
      -- Used to fail-fast when checking for hole-fits. See Note [Speeding up
      -- valid hole-fits].
      tcs_abort_on_insoluble :: Bool,

      -- See Note [WorkList priorities] in GHC.Tc.Solver.InertSet
      tcs_worklist  :: IORef WorkList -- Current worklist
    }

---------------
newtype TcS a = TcS { unTcS :: TcSEnv -> TcM a }
  deriving (Functor)

instance MonadFix TcS where
  mfix k = TcS $ \env -> mfix (\x -> unTcS (k x) env)

-- | Smart constructor for 'TcS', as describe in Note [The one-shot state
-- monad trick] in "GHC.Utils.Monad".
mkTcS :: (TcSEnv -> TcM a) -> TcS a
mkTcS f = TcS (oneShot f)

instance Applicative TcS where
  pure x = mkTcS $ \_ -> return x
  (<*>) = ap

instance Monad TcS where
  m >>= k   = mkTcS $ \ebs -> do
    unTcS m ebs >>= (\r -> unTcS (k r) ebs)

instance MonadIO TcS where
  liftIO act = TcS $ \_env -> liftIO act

instance MonadFail TcS where
  fail err  = mkTcS $ \_ -> fail err

instance MonadUnique TcS where
   getUniqueSupplyM = wrapTcS getUniqueSupplyM

instance HasModule TcS where
   getModule = wrapTcS getModule

instance MonadThings TcS where
   lookupThing n = wrapTcS (lookupThing n)

-- Basic functionality
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
wrapTcS :: TcM a -> TcS a
-- Do not export wrapTcS, because it promotes an arbitrary TcM to TcS,
-- and TcS is supposed to have limited functionality
wrapTcS action = mkTcS $ \_env -> action -- a TcM action will not use the TcEvBinds

wrap2TcS :: (TcM a -> TcM a) -> TcS a -> TcS a
wrap2TcS fn (TcS thing) = mkTcS $ \env -> fn (thing env)

wrapErrTcS :: TcM a -> TcS a
-- The thing wrapped should just fail
-- There's no static check; it's up to the user
-- Having a variant for each error message is too painful
wrapErrTcS = wrapTcS

wrapWarnTcS :: TcM a -> TcS a
-- The thing wrapped should just add a warning, or no-op
-- There's no static check; it's up to the user
wrapWarnTcS = wrapTcS

panicTcS  :: SDoc -> TcS a
failTcS   :: TcRnMessage -> TcS a
warnTcS, addErrTcS :: TcRnMessage -> TcS ()
failTcS      = wrapTcS . TcM.failWith
warnTcS msg  = wrapTcS (TcM.addDiagnostic msg)
addErrTcS    = wrapTcS . TcM.addErr
panicTcS doc = pprPanic "GHC.Tc.Solver.Canonical" doc

-- | Emit a warning within the 'TcS' monad at the location given by the 'CtLoc'.
ctLocWarnTcS :: CtLoc -> TcRnMessage -> TcS ()
ctLocWarnTcS loc msg = wrapTcS $ TcM.setCtLocM loc $ TcM.addDiagnostic msg

traceTcS :: String -> SDoc -> TcS ()
traceTcS herald doc = wrapTcS (TcM.traceTc herald doc)
{-# INLINE traceTcS #-}  -- see Note [INLINE conditional tracing utilities]

runTcPluginTcS :: TcPluginM a -> TcS a
runTcPluginTcS = wrapTcS . runTcPluginM

instance HasDynFlags TcS where
    getDynFlags = wrapTcS getDynFlags

getGlobalRdrEnvTcS :: TcS GlobalRdrEnv
getGlobalRdrEnvTcS = wrapTcS TcM.getGlobalRdrEnv

bumpStepCountTcS :: TcS ()
bumpStepCountTcS = mkTcS $ \env ->
  do { let ref = tcs_count env
     ; n <- TcM.readTcRef ref
     ; TcM.writeTcRef ref (n+1) }

csTraceTcS :: SDoc -> TcS ()
csTraceTcS doc
  = wrapTcS $ csTraceTcM (return doc)
{-# INLINE csTraceTcS #-}  -- see Note [INLINE conditional tracing utilities]

traceFireTcS :: CtEvidence -> SDoc -> TcS ()
-- Dump a rule-firing trace
traceFireTcS ev doc
  = mkTcS $ \env -> csTraceTcM $
    do { n <- TcM.readTcRef (tcs_count env)
       ; tclvl <- TcM.getTcLevel
       ; return (hang (text "Step" <+> int n
                       <> brackets (text "l:" <> ppr tclvl <> comma <>
                                    text "d:" <> ppr (ctLocDepth (ctEvLoc ev)))
                       <+> doc <> colon)
                     4 (ppr ev)) }
{-# INLINE traceFireTcS #-}  -- see Note [INLINE conditional tracing utilities]

csTraceTcM :: TcM SDoc -> TcM ()
-- Constraint-solver tracing, -ddump-cs-trace
csTraceTcM mk_doc
  = do { logger <- getLogger
       ; when (  logHasDumpFlag logger Opt_D_dump_cs_trace
                  || logHasDumpFlag logger Opt_D_dump_tc_trace)
              ( do { msg <- mk_doc
                   ; TcM.dumpTcRn False
                       Opt_D_dump_cs_trace
                       "" FormatText
                       msg }) }
{-# INLINE csTraceTcM #-}  -- see Note [INLINE conditional tracing utilities]

runTcS :: TcS a                -- What to run
       -> TcM (a, EvBindMap)
runTcS tcs
  = do { ev_binds_var <- TcM.newTcEvBinds
       ; res <- runTcSWithEvBinds ev_binds_var tcs
       ; ev_binds <- TcM.getTcEvBindsMap ev_binds_var
       ; return (res, ev_binds) }

-- | This variant of 'runTcS' will immediately fail upon encountering an
-- insoluble ct. See Note [Speeding up valid hole-fits]. Its one usage
-- site does not need the ev_binds, so we do not return them.
runTcSEarlyAbort :: TcS a -> TcM a
runTcSEarlyAbort tcs
  = do { ev_binds_var <- TcM.newTcEvBinds
       ; runTcSWithEvBinds' True True ev_binds_var tcs }

-- | This can deal only with equality constraints.
runTcSEqualities :: TcS a -> TcM a
runTcSEqualities thing_inside
  = do { ev_binds_var <- TcM.newNoTcEvBinds
       ; runTcSWithEvBinds ev_binds_var thing_inside }

-- | A variant of 'runTcS' that takes and returns an 'InertSet' for
-- later resumption of the 'TcS' session.
runTcSInerts :: InertSet -> TcS a -> TcM (a, InertSet)
runTcSInerts inerts tcs = do
  ev_binds_var <- TcM.newTcEvBinds
  runTcSWithEvBinds' False False ev_binds_var $ do
    setTcSInerts inerts
    a <- tcs
    new_inerts <- getTcSInerts
    return (a, new_inerts)

runTcSWithEvBinds :: EvBindsVar
                  -> TcS a
                  -> TcM a
runTcSWithEvBinds = runTcSWithEvBinds' True False

runTcSWithEvBinds' :: Bool -- ^ Restore type variable cycles afterwards?
                           -- Don't if you want to reuse the InertSet.
                           -- See also Note [Type equality cycles]
                           -- in GHC.Tc.Solver.Canonical
                   -> Bool
                   -> EvBindsVar
                   -> TcS a
                   -> TcM a
runTcSWithEvBinds' restore_cycles abort_on_insoluble ev_binds_var tcs
  = do { unified_var <- TcM.newTcRef 0
       ; step_count <- TcM.newTcRef 0
       ; inert_var <- TcM.newTcRef emptyInert
       ; wl_var <- TcM.newTcRef emptyWorkList
       ; unif_lvl_var <- TcM.newTcRef Nothing
       ; let env = TcSEnv { tcs_ev_binds           = ev_binds_var
                          , tcs_unified            = unified_var
                          , tcs_unif_lvl           = unif_lvl_var
                          , tcs_count              = step_count
                          , tcs_inerts             = inert_var
                          , tcs_abort_on_insoluble = abort_on_insoluble
                          , tcs_worklist           = wl_var }

             -- Run the computation
       ; res <- unTcS tcs env

       ; count <- TcM.readTcRef step_count
       ; when (count > 0) $
         csTraceTcM $ return (text "Constraint solver steps =" <+> int count)

       ; when restore_cycles $
         do { inert_set <- TcM.readTcRef inert_var
            ; restoreTyVarCycles inert_set }

#if defined(DEBUG)
       ; ev_binds <- TcM.getTcEvBindsMap ev_binds_var
       ; checkForCyclicBinds ev_binds
#endif

       ; return res }

----------------------------
#if defined(DEBUG)
checkForCyclicBinds :: EvBindMap -> TcM ()
checkForCyclicBinds ev_binds_map
  | null cycles
  = return ()
  | null coercion_cycles
  = TcM.traceTc "Cycle in evidence binds" $ ppr cycles
  | otherwise
  = pprPanic "Cycle in coercion bindings" $ ppr coercion_cycles
  where
    ev_binds = evBindMapBinds ev_binds_map

    cycles :: [[EvBind]]
    cycles = [c | CyclicSCC c <- stronglyConnCompFromEdgedVerticesUniq edges]

    coercion_cycles = [c | c <- cycles, any is_co_bind c]
    is_co_bind (EvBind { eb_lhs = b }) = isEqPrimPred (varType b)

    edges :: [ Node EvVar EvBind ]
    edges = [ DigraphNode bind bndr (nonDetEltsUniqSet (evVarsOfTerm rhs))
            | bind@(EvBind { eb_lhs = bndr, eb_rhs = rhs}) <- bagToList ev_binds ]
            -- It's OK to use nonDetEltsUFM here as
            -- stronglyConnCompFromEdgedVertices is still deterministic even
            -- if the edges are in nondeterministic order as explained in
            -- Note [Deterministic SCC] in GHC.Data.Graph.Directed.
#endif

----------------------------
setEvBindsTcS :: EvBindsVar -> TcS a -> TcS a
setEvBindsTcS ref (TcS thing_inside)
 = TcS $ \ env -> thing_inside (env { tcs_ev_binds = ref })

nestImplicTcS :: EvBindsVar
              -> TcLevel -> TcS a
              -> TcS a
nestImplicTcS ref inner_tclvl (TcS thing_inside)
  = TcS $ \ TcSEnv { tcs_unified            = unified_var
                   , tcs_inerts             = old_inert_var
                   , tcs_count              = count
                   , tcs_unif_lvl           = unif_lvl
                   , tcs_abort_on_insoluble = abort_on_insoluble
                   } ->
    do { inerts <- TcM.readTcRef old_inert_var
       ; let nest_inert = inerts { inert_cycle_breakers = pushCycleBreakerVarStack
                                                            (inert_cycle_breakers inerts)
                                 , inert_cans = (inert_cans inerts)
                                                   { inert_given_eqs = False } }
                 -- All other InertSet fields are inherited
       ; new_inert_var <- TcM.newTcRef nest_inert
       ; new_wl_var    <- TcM.newTcRef emptyWorkList
       ; let nest_env = TcSEnv { tcs_count              = count     -- Inherited
                               , tcs_unif_lvl           = unif_lvl  -- Inherited
                               , tcs_ev_binds           = ref
                               , tcs_unified            = unified_var
                               , tcs_inerts             = new_inert_var
                               , tcs_abort_on_insoluble = abort_on_insoluble
                               , tcs_worklist           = new_wl_var }
       ; res <- TcM.setTcLevel inner_tclvl $
                thing_inside nest_env

       ; out_inert_set <- TcM.readTcRef new_inert_var
       ; restoreTyVarCycles out_inert_set

#if defined(DEBUG)
       -- Perform a check that the thing_inside did not cause cycles
       ; ev_binds <- TcM.getTcEvBindsMap ref
       ; checkForCyclicBinds ev_binds
#endif
       ; return res }

nestTcS ::  TcS a -> TcS a
-- Use the current untouchables, augmenting the current
-- evidence bindings, and solved dictionaries
-- But have no effect on the InertCans, or on the inert_famapp_cache
-- (we want to inherit the latter from processing the Givens)
nestTcS (TcS thing_inside)
  = TcS $ \ env@(TcSEnv { tcs_inerts = inerts_var }) ->
    do { inerts <- TcM.readTcRef inerts_var
       ; new_inert_var <- TcM.newTcRef inerts
       ; new_wl_var    <- TcM.newTcRef emptyWorkList
       ; let nest_env = env { tcs_inerts   = new_inert_var
                            , tcs_worklist = new_wl_var }

       ; res <- thing_inside nest_env

       ; new_inerts <- TcM.readTcRef new_inert_var

       -- we want to propagate the safe haskell failures
       ; let old_ic = inert_cans inerts
             new_ic = inert_cans new_inerts
             nxt_ic = old_ic { inert_safehask = inert_safehask new_ic }

       ; TcM.writeTcRef inerts_var  -- See Note [Propagate the solved dictionaries]
                        (inerts { inert_solved_dicts = inert_solved_dicts new_inerts
                                , inert_cans = nxt_ic })

       ; return res }

emitImplicationTcS :: TcLevel -> SkolemInfoAnon
                   -> [TcTyVar]        -- Skolems
                   -> [EvVar]          -- Givens
                   -> Cts              -- Wanteds
                   -> TcS TcEvBinds
-- Add an implication to the TcS monad work-list
emitImplicationTcS new_tclvl skol_info skol_tvs givens wanteds
  = do { let wc = emptyWC { wc_simple = wanteds }
       ; imp <- wrapTcS $
                do { ev_binds_var <- TcM.newTcEvBinds
                   ; imp <- TcM.newImplication
                   ; return (imp { ic_tclvl  = new_tclvl
                                 , ic_skols  = skol_tvs
                                 , ic_given  = givens
                                 , ic_wanted = wc
                                 , ic_binds  = ev_binds_var
                                 , ic_info   = skol_info }) }

       ; emitImplication imp
       ; return (TcEvBinds (ic_binds imp)) }

emitTvImplicationTcS :: TcLevel -> SkolemInfoAnon
                     -> [TcTyVar]        -- Skolems
                     -> Cts              -- Wanteds
                     -> TcS ()
-- Just like emitImplicationTcS but no givens and no bindings
emitTvImplicationTcS new_tclvl skol_info skol_tvs wanteds
  = do { let wc = emptyWC { wc_simple = wanteds }
       ; imp <- wrapTcS $
                do { ev_binds_var <- TcM.newNoTcEvBinds
                   ; imp <- TcM.newImplication
                   ; return (imp { ic_tclvl  = new_tclvl
                                 , ic_skols  = skol_tvs
                                 , ic_wanted = wc
                                 , ic_binds  = ev_binds_var
                                 , ic_info   = skol_info }) }

       ; emitImplication imp }


{- Note [Propagate the solved dictionaries]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
It's really quite important that nestTcS does not discard the solved
dictionaries from the thing_inside.
Consider
   Eq [a]
   forall b. empty =>  Eq [a]
We solve the simple (Eq [a]), under nestTcS, and then turn our attention to
the implications.  It's definitely fine to use the solved dictionaries on
the inner implications, and it can make a significant performance difference
if you do so.
-}

-- Getters and setters of GHC.Tc.Utils.Env fields
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Getter of inerts and worklist
getTcSInertsRef :: TcS (IORef InertSet)
getTcSInertsRef = TcS (return . tcs_inerts)

getTcSWorkListRef :: TcS (IORef WorkList)
getTcSWorkListRef = TcS (return . tcs_worklist)

getTcSInerts :: TcS InertSet
getTcSInerts = getTcSInertsRef >>= readTcRef

setTcSInerts :: InertSet -> TcS ()
setTcSInerts ics = do { r <- getTcSInertsRef; writeTcRef r ics }

getWorkListImplics :: TcS (Bag Implication)
getWorkListImplics
  = do { wl_var <- getTcSWorkListRef
       ; wl_curr <- readTcRef wl_var
       ; return (wl_implics wl_curr) }

pushLevelNoWorkList :: SDoc -> TcS a -> TcS (TcLevel, a)
-- Push the level and run thing_inside
-- However, thing_inside should not generate any work items
#if defined(DEBUG)
pushLevelNoWorkList err_doc (TcS thing_inside)
  = TcS (\env -> TcM.pushTcLevelM $
                 thing_inside (env { tcs_worklist = wl_panic })
        )
  where
    wl_panic  = pprPanic "GHC.Tc.Solver.Monad.buildImplication" err_doc
                         -- This panic checks that the thing-inside
                         -- does not emit any work-list constraints
#else
pushLevelNoWorkList _ (TcS thing_inside)
  = TcS (\env -> TcM.pushTcLevelM (thing_inside env))  -- Don't check
#endif

updWorkListTcS :: (WorkList -> WorkList) -> TcS ()
updWorkListTcS f
  = do { wl_var <- getTcSWorkListRef
       ; updTcRef wl_var f }

emitWorkNC :: [CtEvidence] -> TcS ()
emitWorkNC evs
  | null evs
  = return ()
  | otherwise
  = emitWork (map mkNonCanonical evs)

emitWork :: [Ct] -> TcS ()
emitWork [] = return ()   -- avoid printing, among other work
emitWork cts
  = do { traceTcS "Emitting fresh work" (vcat (map ppr cts))
       ; updWorkListTcS (extendWorkListCts cts) }

emitImplication :: Implication -> TcS ()
emitImplication implic
  = updWorkListTcS (extendWorkListImplic implic)

newTcRef :: a -> TcS (TcRef a)
newTcRef x = wrapTcS (TcM.newTcRef x)

readTcRef :: TcRef a -> TcS a
readTcRef ref = wrapTcS (TcM.readTcRef ref)

writeTcRef :: TcRef a -> a -> TcS ()
writeTcRef ref val = wrapTcS (TcM.writeTcRef ref val)

updTcRef :: TcRef a -> (a->a) -> TcS ()
updTcRef ref upd_fn = wrapTcS (TcM.updTcRef ref upd_fn)

getTcEvBindsVar :: TcS EvBindsVar
getTcEvBindsVar = TcS (return . tcs_ev_binds)

getTcLevel :: TcS TcLevel
getTcLevel = wrapTcS TcM.getTcLevel

getTcEvTyCoVars :: EvBindsVar -> TcS TyCoVarSet
getTcEvTyCoVars ev_binds_var
  = wrapTcS $ TcM.getTcEvTyCoVars ev_binds_var

getTcEvBindsMap :: EvBindsVar -> TcS EvBindMap
getTcEvBindsMap ev_binds_var
  = wrapTcS $ TcM.getTcEvBindsMap ev_binds_var

setTcEvBindsMap :: EvBindsVar -> EvBindMap -> TcS ()
setTcEvBindsMap ev_binds_var binds
  = wrapTcS $ TcM.setTcEvBindsMap ev_binds_var binds

unifyTyVar :: TcTyVar -> TcType -> TcS ()
-- Unify a meta-tyvar with a type
-- We keep track of how many unifications have happened in tcs_unified,
--
-- We should never unify the same variable twice!
unifyTyVar tv ty
  = assertPpr (isMetaTyVar tv) (ppr tv) $
    TcS $ \ env ->
    do { TcM.traceTc "unifyTyVar" (ppr tv <+> text ":=" <+> ppr ty)
       ; TcM.writeMetaTyVar tv ty
       ; TcM.updTcRef (tcs_unified env) (+1) }

reportUnifications :: TcS a -> TcS (Int, a)
reportUnifications (TcS thing_inside)
  = TcS $ \ env ->
    do { inner_unified <- TcM.newTcRef 0
       ; res <- thing_inside (env { tcs_unified = inner_unified })
       ; n_unifs <- TcM.readTcRef inner_unified
       ; TcM.updTcRef (tcs_unified env) (+ n_unifs)
       ; return (n_unifs, res) }

data TouchabilityTestResult
  -- See Note [Solve by unification] in GHC.Tc.Solver.Interact
  -- which points out that having TouchableSameLevel is just an optimisation;
  -- we could manage with TouchableOuterLevel alone (suitably renamed)
  = TouchableSameLevel
  | TouchableOuterLevel [TcTyVar]   -- Promote these
                        TcLevel     -- ..to this level
  | Untouchable

instance Outputable TouchabilityTestResult where
  ppr TouchableSameLevel            = text "TouchableSameLevel"
  ppr (TouchableOuterLevel tvs lvl) = text "TouchableOuterLevel" <> parens (ppr lvl <+> ppr tvs)
  ppr Untouchable                   = text "Untouchable"

touchabilityTest :: CtFlavour -> TcTyVar -> TcType -> TcS (TouchabilityTestResult, TcType)
-- ^ This is the key test for untouchability:
-- See Note [Unification preconditions] in GHC.Tc.Utils.Unify
-- and Note [Solve by unification] in GHC.Tc.Solver.Interact
--
-- Returns a new rhs type, as this function can turn make some metavariables concrete.
touchabilityTest flav tv1 rhs
  | flav /= Given  -- See Note [Do not unify Givens]
  , MetaTv { mtv_tclvl = tv_lvl, mtv_info = info } <- tcTyVarDetails tv1
  = do { continue_solving <- wrapTcS $ startSolvingByUnification info rhs
       ; case continue_solving of
       { Nothing -> return (Untouchable, rhs)
       ; Just rhs ->
    do { let (free_metas, free_skols) = partition isPromotableMetaTyVar $
                                        nonDetEltsUniqSet               $
                                        tyCoVarsOfType rhs
       ; ambient_lvl  <- getTcLevel
       ; given_eq_lvl <- getInnermostGivenEqLevel

       ; if | tv_lvl `sameDepthAs` ambient_lvl
            -> return (TouchableSameLevel, rhs)

            | tv_lvl `deeperThanOrSame` given_eq_lvl   -- No intervening given equalities
            , all (does_not_escape tv_lvl) free_skols  -- No skolem escapes
            -> return (TouchableOuterLevel free_metas tv_lvl, rhs)

            | otherwise
            -> return (Untouchable, rhs) } } }
  | otherwise
  = return (Untouchable, rhs)
  where

     does_not_escape tv_lvl fv
       | isTyVar fv = tv_lvl `deeperThanOrSame` tcTyVarLevel fv
       | otherwise  = True
       -- Coercion variables are not an escape risk
       -- If an implication binds a coercion variable, it'll have equalities,
       -- so the "intervening given equalities" test above will catch it
       -- Coercion holes get filled with coercions, so again no problem.

{- Note [Do not unify Givens]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider this GADT match
   data T a where
      T1 :: T Int
      ...

   f x = case x of
           T1 -> True
           ...

So we get f :: T alpha[1] -> beta[1]
          x :: T alpha[1]
and from the T1 branch we get the implication
   forall[2] (alpha[1] ~ Int) => beta[1] ~ Bool

Now, clearly we don't want to unify alpha:=Int!  Yet at the moment we
process [G] alpha[1] ~ Int, we don't have any given-equalities in the
inert set, and hence there are no given equalities to make alpha untouchable.

NB: if it were alpha[2] ~ Int, this argument wouldn't hold.  But that
never happens: invariant (GivenInv) in Note [TcLevel invariants]
in GHC.Tc.Utils.TcType.

Simple solution: never unify in Givens!
-}

getDefaultInfo ::  TcS ([Type], (Bool, Bool))
getDefaultInfo = wrapTcS TcM.tcGetDefaultTys

getWorkList :: TcS WorkList
getWorkList = do { wl_var <- getTcSWorkListRef
                 ; wrapTcS (TcM.readTcRef wl_var) }

selectNextWorkItem :: TcS (Maybe Ct)
-- Pick which work item to do next
-- See Note [Prioritise equalities]
selectNextWorkItem
  = do { wl_var <- getTcSWorkListRef
       ; wl <- readTcRef wl_var
       ; case selectWorkItem wl of {
           Nothing -> return Nothing ;
           Just (ct, new_wl) ->
    do { -- checkReductionDepth (ctLoc ct) (ctPred ct)
         -- This is done by GHC.Tc.Solver.Interact.chooseInstance
       ; writeTcRef wl_var new_wl
       ; return (Just ct) } } }

-- Just get some environments needed for instance looking up and matching
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

getInstEnvs :: TcS InstEnvs
getInstEnvs = wrapTcS $ TcM.tcGetInstEnvs

getFamInstEnvs :: TcS (FamInstEnv, FamInstEnv)
getFamInstEnvs = wrapTcS $ FamInst.tcGetFamInstEnvs

getTopEnv :: TcS HscEnv
getTopEnv = wrapTcS $ TcM.getTopEnv

getGblEnv :: TcS TcGblEnv
getGblEnv = wrapTcS $ TcM.getGblEnv

getLclEnv :: TcS TcLclEnv
getLclEnv = wrapTcS $ TcM.getLclEnv

setLclEnv :: TcLclEnv -> TcS a -> TcS a
setLclEnv env = wrap2TcS (TcM.setLclEnv env)

tcLookupClass :: Name -> TcS Class
tcLookupClass c = wrapTcS $ TcM.tcLookupClass c

tcLookupId :: Name -> TcS Id
tcLookupId n = wrapTcS $ TcM.tcLookupId n

-- Any use of this function is a bit suspect, because it violates the
-- pure veneer of TcS. But it's just about warnings around unused imports
-- and local constructors (GHC will issue fewer warnings than it otherwise
-- might), so it's not worth losing sleep over.
recordUsedGREs :: Bag GlobalRdrElt -> TcS ()
recordUsedGREs gres
  = do { wrapTcS $ TcM.addUsedGREs gre_list
         -- If a newtype constructor was imported, don't warn about not
         -- importing it...
       ; wrapTcS $ traverse_ (TcM.keepAlive . greMangledName) gre_list }
         -- ...and similarly, if a newtype constructor was defined in the same
         -- module, don't warn about it being unused.
         -- See Note [Tracking unused binding and imports] in GHC.Tc.Utils.

  where
    gre_list = bagToList gres

-- Various smaller utilities [TODO, maybe will be absorbed in the instance matcher]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

checkWellStagedDFun :: CtLoc -> InstanceWhat -> PredType -> TcS ()
-- Check that we do not try to use an instance before it is available.  E.g.
--    instance Eq T where ...
--    f x = $( ... (\(p::T) -> p == p)... )
-- Here we can't use the equality function from the instance in the splice

checkWellStagedDFun loc what pred
  = do
      mbind_lvl <- checkWellStagedInstanceWhat what
      case mbind_lvl of
        Just bind_lvl | bind_lvl > impLevel ->
          wrapTcS $ TcM.setCtLocM loc $ do
              { use_stage <- TcM.getStage
              ; TcM.checkWellStaged pp_thing bind_lvl (thLevel use_stage) }
        _ ->
          return ()
  where
    pp_thing = text "instance for" <+> quotes (ppr pred)

-- | Returns the ThLevel of evidence for the solved constraint (if it has evidence)
-- See Note [Well-staged instance evidence]
checkWellStagedInstanceWhat :: InstanceWhat -> TcS (Maybe ThLevel)
checkWellStagedInstanceWhat what
  | TopLevInstance { iw_dfun_id = dfun_id } <- what
    = return $ Just (TcM.topIdLvl dfun_id)
  | BuiltinTypeableInstance tc <- what
    = do
        cur_mod <- extractModule <$> getGblEnv
        return $ Just (if nameIsLocalOrFrom cur_mod (tyConName tc)
                        then outerLevel
                        else impLevel)
  | otherwise = return Nothing

{-
Note [Well-staged instance evidence]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Evidence for instances must obey the same level restrictions as normal bindings.
In particular, it is forbidden to use an instance in a top-level splice in the
module which the instance is defined. This is because the evidence is bound at
the top-level and top-level definitions are forbidden from being using in top-level splices in
the same module.

For example, suppose you have a function..  foo :: Show a => Code Q a -> Code Q ()
then the following program is disallowed,

```
data T a = T a deriving (Show)

main :: IO ()
main =
  let x = $$(foo [|| T () ||])
  in return ()
```

because the `foo` function (used in a top-level splice) requires `Show T` evidence,
which is defined at the top-level and therefore fails with an error that we have violated
the stage restriction.

```
Main.hs:12:14: error:
    • GHC stage restriction:
        instance for ‘Show
                        (T ())’ is used in a top-level splice, quasi-quote, or annotation,
        and must be imported, not defined locally
    • In the expression: foo [|| T () ||]
      In the Template Haskell splice $$(foo [|| T () ||])
      In the expression: $$(foo [|| T () ||])
   |
12 |   let x = $$(foo [|| T () ||])
   |
```

Solving a `Typeable (T t1 ...tn)` constraint generates code that relies on
`$tcT`, the `TypeRep` for `T`; and we must check that this reference to `$tcT`
is well staged.  It's easy to know the stage of `$tcT`: for imported TyCons it
will be `impLevel`, and for local TyCons it will be `toplevel`.

Therefore the `InstanceWhat` type had to be extended with
a special case for `Typeable`, which recorded the TyCon the evidence was for and
could them be used to check that we were not attempting to evidence in a stage incorrect
manner.

-}

pprEq :: TcType -> TcType -> SDoc
pprEq ty1 ty2 = pprParendType ty1 <+> char '~' <+> pprParendType ty2

isFilledMetaTyVar_maybe :: TcTyVar -> TcS (Maybe Type)
isFilledMetaTyVar_maybe tv = wrapTcS (TcM.isFilledMetaTyVar_maybe tv)

isFilledMetaTyVar :: TcTyVar -> TcS Bool
isFilledMetaTyVar tv = wrapTcS (TcM.isFilledMetaTyVar tv)

zonkTyCoVarsAndFV :: TcTyCoVarSet -> TcS TcTyCoVarSet
zonkTyCoVarsAndFV tvs = wrapTcS (TcM.zonkTyCoVarsAndFV tvs)

zonkTyCoVarsAndFVList :: [TcTyCoVar] -> TcS [TcTyCoVar]
zonkTyCoVarsAndFVList tvs = wrapTcS (TcM.zonkTyCoVarsAndFVList tvs)

zonkCo :: Coercion -> TcS Coercion
zonkCo = wrapTcS . TcM.zonkCo

zonkTcType :: TcType -> TcS TcType
zonkTcType ty = wrapTcS (TcM.zonkTcType ty)

zonkTcTypes :: [TcType] -> TcS [TcType]
zonkTcTypes tys = wrapTcS (TcM.zonkTcTypes tys)

zonkTcTyVar :: TcTyVar -> TcS TcType
zonkTcTyVar tv = wrapTcS (TcM.zonkTcTyVar tv)

zonkSimples :: Cts -> TcS Cts
zonkSimples cts = wrapTcS (TcM.zonkSimples cts)

zonkWC :: WantedConstraints -> TcS WantedConstraints
zonkWC wc = wrapTcS (TcM.zonkWC wc)

zonkTyCoVarKind :: TcTyCoVar -> TcS TcTyCoVar
zonkTyCoVarKind tv = wrapTcS (TcM.zonkTyCoVarKind tv)

----------------------------
pprKicked :: Int -> SDoc
pprKicked 0 = empty
pprKicked n = parens (int n <+> text "kicked out")

{- *********************************************************************
*                                                                      *
*              The Unification Level Flag                              *
*                                                                      *
********************************************************************* -}

{- Note [The Unification Level Flag]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider a deep tree of implication constraints
   forall[1] a.                              -- Outer-implic
      C alpha[1]                               -- Simple
      forall[2] c. ....(C alpha[1])....        -- Implic-1
      forall[2] b. ....(alpha[1] ~ Int)....    -- Implic-2

The (C alpha) is insoluble until we know alpha.  We solve alpha
by unifying alpha:=Int somewhere deep inside Implic-2. But then we
must try to solve the Outer-implic all over again. This time we can
solve (C alpha) both in Outer-implic, and nested inside Implic-1.

When should we iterate solving a level-n implication?
Answer: if any unification of a tyvar at level n takes place
        in the ic_implics of that implication.

* What if a unification takes place at level n-1? Then don't iterate
  level n, because we'll iterate level n-1, and that will in turn iterate
  level n.

* What if a unification takes place at level n, in the ic_simples of
  level n?  No need to track this, because the kick-out mechanism deals
  with it.  (We can't drop kick-out in favour of iteration, because kick-out
  works for skolem-equalities, not just unifications.)

So the monad-global Unification Level Flag, kept in tcs_unif_lvl keeps
track of
  - Whether any unifications at all have taken place (Nothing => no unifications)
  - If so, what is the outermost level that has seen a unification (Just lvl)

The iteration done in the simplify_loop/maybe_simplify_again loop in GHC.Tc.Solver.

It helpful not to iterate unless there is a chance of progress.  #8474 is
an example:

  * There's a deeply-nested chain of implication constraints.
       ?x:alpha => ?y1:beta1 => ... ?yn:betan => [W] ?x:Int

  * From the innermost one we get a [W] alpha[1] ~ Int,
    so we can unify.

  * It's better not to iterate the inner implications, but go all the
    way out to level 1 before iterating -- because iterating level 1
    will iterate the inner levels anyway.

(In the olden days when we "floated" thse Derived constraints, this was
much, much more important -- we got exponential behaviour, as each iteration
produced the same Derived constraint.)
-}


resetUnificationFlag :: TcS Bool
-- We are at ambient level i
-- If the unification flag = Just i, reset it to Nothing and return True
-- Otherwise leave it unchanged and return False
resetUnificationFlag
  = TcS $ \env ->
    do { let ref = tcs_unif_lvl env
       ; ambient_lvl <- TcM.getTcLevel
       ; mb_lvl <- TcM.readTcRef ref
       ; TcM.traceTc "resetUnificationFlag" $
         vcat [ text "ambient:" <+> ppr ambient_lvl
              , text "unif_lvl:" <+> ppr mb_lvl ]
       ; case mb_lvl of
           Nothing       -> return False
           Just unif_lvl | ambient_lvl `strictlyDeeperThan` unif_lvl
                         -> return False
                         | otherwise
                         -> do { TcM.writeTcRef ref Nothing
                               ; return True } }

setUnificationFlag :: TcLevel -> TcS ()
-- (setUnificationFlag i) sets the unification level to (Just i)
-- unless it already is (Just j) where j <= i
setUnificationFlag lvl
  = TcS $ \env ->
    do { let ref = tcs_unif_lvl env
       ; mb_lvl <- TcM.readTcRef ref
       ; case mb_lvl of
           Just unif_lvl | lvl `deeperThanOrSame` unif_lvl
                         -> return ()
           _ -> TcM.writeTcRef ref (Just lvl) }


{- *********************************************************************
*                                                                      *
*                Instantiation etc.
*                                                                      *
********************************************************************* -}

-- Instantiations
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

instDFunType :: DFunId -> [DFunInstType] -> TcS ([TcType], TcThetaType)
instDFunType dfun_id inst_tys
  = wrapTcS $ TcM.instDFunType dfun_id inst_tys

newFlexiTcSTy :: Kind -> TcS TcType
newFlexiTcSTy knd = wrapTcS (TcM.newFlexiTyVarTy knd)

cloneMetaTyVar :: TcTyVar -> TcS TcTyVar
cloneMetaTyVar tv = wrapTcS (TcM.cloneMetaTyVar tv)

instFlexiX :: Subst -> [TKVar] -> TcS Subst
instFlexiX subst tvs
  = wrapTcS (foldlM instFlexiHelper subst tvs)

instFlexiHelper :: Subst -> TKVar -> TcM Subst
-- Makes fresh tyvar, extends the substitution, and the in-scope set
instFlexiHelper subst tv
  = do { uniq <- TcM.newUnique
       ; details <- TcM.newMetaDetails TauTv
       ; let name   = setNameUnique (tyVarName tv) uniq
             kind   = substTyUnchecked subst (tyVarKind tv)
             tv'    = mkTcTyVar name kind details
             subst' = extendTvSubstWithClone subst tv tv'
       ; TcM.traceTc "instFlexi" (ppr tv')
       ; return (extendTvSubst subst' tv (mkTyVarTy tv')) }

matchGlobalInst :: DynFlags
                -> Bool      -- True <=> caller is the short-cut solver
                             -- See Note [Shortcut solving: overlap]
                -> Class -> [Type] -> TcS TcM.ClsInstResult
matchGlobalInst dflags short_cut cls tys
  = wrapTcS (TcM.matchGlobalInst dflags short_cut cls tys)

tcInstSkolTyVarsX :: SkolemInfo -> Subst -> [TyVar] -> TcS (Subst, [TcTyVar])
tcInstSkolTyVarsX skol_info subst tvs = wrapTcS $ TcM.tcInstSkolTyVarsX skol_info subst tvs

-- Creating and setting evidence variables and CtFlavors
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

data MaybeNew = Fresh CtEvidence | Cached EvExpr

isFresh :: MaybeNew -> Bool
isFresh (Fresh {})  = True
isFresh (Cached {}) = False

freshGoals :: [MaybeNew] -> [CtEvidence]
freshGoals mns = [ ctev | Fresh ctev <- mns ]

getEvExpr :: MaybeNew -> EvExpr
getEvExpr (Fresh ctev) = ctEvExpr ctev
getEvExpr (Cached evt) = evt

setEvBind :: EvBind -> TcS ()
setEvBind ev_bind
  = do { evb <- getTcEvBindsVar
       ; wrapTcS $ TcM.addTcEvBind evb ev_bind }

-- | Mark variables as used filling a coercion hole
useVars :: CoVarSet -> TcS ()
useVars co_vars
  = do { ev_binds_var <- getTcEvBindsVar
       ; let ref = ebv_tcvs ev_binds_var
       ; wrapTcS $
         do { tcvs <- TcM.readTcRef ref
            ; let tcvs' = tcvs `unionVarSet` co_vars
            ; TcM.writeTcRef ref tcvs' } }

-- | Equalities only
setWantedEq :: HasDebugCallStack => TcEvDest -> Coercion -> TcS ()
setWantedEq (HoleDest hole) co
  = do { useVars (coVarsOfCo co)
       ; fillCoercionHole hole co }
setWantedEq (EvVarDest ev) _ = pprPanic "setWantedEq: EvVarDest" (ppr ev)

-- | Good for both equalities and non-equalities
setWantedEvTerm :: TcEvDest -> EvTerm -> TcS ()
setWantedEvTerm (HoleDest hole) tm
  | Just co <- evTermCoercion_maybe tm
  = do { useVars (coVarsOfCo co)
       ; fillCoercionHole hole co }
  | otherwise
  = -- See Note [Yukky eq_sel for a HoleDest]
    do { let co_var = coHoleCoVar hole
       ; setEvBind (mkWantedEvBind co_var tm)
       ; fillCoercionHole hole (mkCoVarCo co_var) }

setWantedEvTerm (EvVarDest ev_id) tm
  = setEvBind (mkWantedEvBind ev_id tm)

{- Note [Yukky eq_sel for a HoleDest]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
How can it be that a Wanted with HoleDest gets evidence that isn't
just a coercion? i.e. evTermCoercion_maybe returns Nothing.

Consider [G] forall a. blah => a ~ T
         [W] S ~# T

Then doTopReactEqPred carefully looks up the (boxed) constraint (S ~ T)
in the quantified constraints, and wraps the (boxed) evidence it
gets back in an eq_sel to extract the unboxed (S ~# T).  We can't put
that term into a coercion, so we add a value binding
    h = eq_sel (...)
and the coercion variable h to fill the coercion hole.
We even re-use the CoHole's Id for this binding!

Yuk!
-}

fillCoercionHole :: CoercionHole -> Coercion -> TcS ()
fillCoercionHole hole co
  = do { wrapTcS $ TcM.fillCoercionHole hole co
       ; kickOutAfterFillingCoercionHole hole }

setEvBindIfWanted :: CtEvidence -> EvTerm -> TcS ()
setEvBindIfWanted ev tm
  = case ev of
      CtWanted { ctev_dest = dest } -> setWantedEvTerm dest tm
      _                             -> return ()

newTcEvBinds :: TcS EvBindsVar
newTcEvBinds = wrapTcS TcM.newTcEvBinds

newNoTcEvBinds :: TcS EvBindsVar
newNoTcEvBinds = wrapTcS TcM.newNoTcEvBinds

newEvVar :: TcPredType -> TcS EvVar
newEvVar pred = wrapTcS (TcM.newEvVar pred)

newGivenEvVar :: CtLoc -> (TcPredType, EvTerm) -> TcS CtEvidence
-- Make a new variable of the given PredType,
-- immediately bind it to the given term
-- and return its CtEvidence
-- See Note [Bind new Givens immediately] in GHC.Tc.Types.Constraint
newGivenEvVar loc (pred, rhs)
  = do { new_ev <- newBoundEvVarId pred rhs
       ; return (CtGiven { ctev_pred = pred, ctev_evar = new_ev, ctev_loc = loc }) }

-- | Make a new 'Id' of the given type, bound (in the monad's EvBinds) to the
-- given term
newBoundEvVarId :: TcPredType -> EvTerm -> TcS EvVar
newBoundEvVarId pred rhs
  = do { new_ev <- newEvVar pred
       ; setEvBind (mkGivenEvBind new_ev rhs)
       ; return new_ev }

newGivenEvVars :: CtLoc -> [(TcPredType, EvTerm)] -> TcS [CtEvidence]
newGivenEvVars loc pts = mapM (newGivenEvVar loc) pts

emitNewWantedEq :: CtLoc -> RewriterSet -> Role -> TcType -> TcType -> TcS Coercion
-- | Emit a new Wanted equality into the work-list
emitNewWantedEq loc rewriters role ty1 ty2
  = do { (ev, co) <- newWantedEq loc rewriters role ty1 ty2
       ; updWorkListTcS (extendWorkListEq (mkNonCanonical ev))
       ; return co }

-- | Create a new Wanted constraint holding a coercion hole
-- for an equality between the two types at the given 'Role'.
newWantedEq :: CtLoc -> RewriterSet -> Role -> TcType -> TcType
            -> TcS (CtEvidence, Coercion)
newWantedEq loc rewriters role ty1 ty2
  = do { hole <- wrapTcS $ TcM.newCoercionHole pty
       ; traceTcS "Emitting new coercion hole" (ppr hole <+> dcolon <+> ppr pty)
       ; return ( CtWanted { ctev_pred      = pty
                           , ctev_dest      = HoleDest hole
                           , ctev_loc       = loc
                           , ctev_rewriters = rewriters }
                , mkHoleCo hole ) }
  where
    pty = mkPrimEqPredRole role ty1 ty2

-- | Create a new Wanted constraint holding an evidence variable.
--
-- Don't use this for equality constraints: use 'newWantedEq' instead.
newWantedEvVarNC :: CtLoc -> RewriterSet
                 -> TcPredType -> TcS CtEvidence
-- Don't look up in the solved/inerts; we know it's not there
newWantedEvVarNC loc rewriters pty
  = do { new_ev <- newEvVar pty
       ; traceTcS "Emitting new wanted" (ppr new_ev <+> dcolon <+> ppr pty $$
                                         pprCtLoc loc)
       ; return (CtWanted { ctev_pred      = pty
                          , ctev_dest      = EvVarDest new_ev
                          , ctev_loc       = loc
                          , ctev_rewriters = rewriters })}

-- | Like 'newWantedEvVarNC', except it might look up in the inert set
-- to see if an inert already exists, and uses that instead of creating
-- a new Wanted constraint.
--
-- Don't use this for equality constraints: this function is only for
-- constraints with 'EvVarDest'.
newWantedEvVar :: CtLoc -> RewriterSet
               -> TcPredType -> TcS MaybeNew
-- For anything except ClassPred, this is the same as newWantedEvVarNC
newWantedEvVar loc rewriters pty
  = assertPpr (not (isEqPrimPred pty))
      (vcat [ text "newWantedEvVar: HoleDestPred"
            , text "pty:" <+> ppr pty ]) $
    do { mb_ct <- lookupInInerts loc pty
       ; case mb_ct of
            Just ctev
              -> do { traceTcS "newWantedEvVar/cache hit" $ ppr ctev
                    ; return $ Cached (ctEvExpr ctev) }
            _ -> do { ctev <- newWantedEvVarNC loc rewriters pty
                    ; return (Fresh ctev) } }

-- | Create a new Wanted constraint, potentially looking up
-- non-equality constraints in the cache instead of creating
-- a new one from scratch.
--
-- Deals with both equality and non-equality constraints.
newWanted :: CtLoc -> RewriterSet -> PredType -> TcS MaybeNew
newWanted loc rewriters pty
  | Just (role, ty1, ty2) <- getEqPredTys_maybe pty
  = Fresh . fst <$> newWantedEq loc rewriters role ty1 ty2
  | otherwise
  = newWantedEvVar loc rewriters pty

-- | Create a new Wanted constraint.
--
-- Deals with both equality and non-equality constraints.
--
-- Does not attempt to re-use non-equality constraints that already
-- exist in the inert set.
newWantedNC :: CtLoc -> RewriterSet -> PredType -> TcS CtEvidence
newWantedNC loc rewriters pty
  | Just (role, ty1, ty2) <- getEqPredTys_maybe pty
  = fst <$> newWantedEq loc rewriters role ty1 ty2
  | otherwise
  = newWantedEvVarNC loc rewriters pty

-- --------- Check done in GHC.Tc.Solver.Interact.selectNewWorkItem???? ---------
-- | Checks if the depth of the given location is too much. Fails if
-- it's too big, with an appropriate error message.
checkReductionDepth :: CtLoc -> TcType   -- ^ type being reduced
                    -> TcS ()
checkReductionDepth loc ty
  = do { dflags <- getDynFlags
       ; when (subGoalDepthExceeded dflags (ctLocDepth loc)) $
         wrapErrTcS $ solverDepthError loc ty }

matchFam :: TyCon -> [Type] -> TcS (Maybe ReductionN)
matchFam tycon args = wrapTcS $ matchFamTcM tycon args

matchFamTcM :: TyCon -> [Type] -> TcM (Maybe ReductionN)
-- Given (F tys) return (ty, co), where co :: F tys ~N ty
matchFamTcM tycon args
  = do { fam_envs <- FamInst.tcGetFamInstEnvs
       ; let match_fam_result
              = reduceTyFamApp_maybe fam_envs Nominal tycon args
       ; TcM.traceTc "matchFamTcM" $
         vcat [ text "Matching:" <+> ppr (mkTyConApp tycon args)
              , ppr_res match_fam_result ]
       ; return match_fam_result }
  where
    ppr_res Nothing = text "Match failed"
    ppr_res (Just (Reduction co ty))
      = hang (text "Match succeeded:")
          2 (vcat [ text "Rewrites to:" <+> ppr ty
                  , text "Coercion:" <+> ppr co ])

solverDepthError :: CtLoc -> TcType -> TcM a
solverDepthError loc ty
  = TcM.setCtLocM loc $
    do { ty <- TcM.zonkTcType ty
       ; env0 <- TcM.tcInitTidyEnv
       ; let tidy_env     = tidyFreeTyCoVars env0 (tyCoVarsOfTypeList ty)
             tidy_ty      = tidyType tidy_env ty
             msg = mkTcRnUnknownMessage $ mkPlainError noHints $
               vcat [ text "Reduction stack overflow; size =" <+> ppr depth
                      , hang (text "When simplifying the following type:")
                           2 (ppr tidy_ty)
                      , note ]
       ; TcM.failWithTcM (tidy_env, msg) }
  where
    depth = ctLocDepth loc
    note = vcat
      [ text "Use -freduction-depth=0 to disable this check"
      , text "(any upper bound you could choose might fail unpredictably with"
      , text " minor updates to GHC, so disabling the check is recommended if"
      , text " you're sure that type checking should terminate)" ]


{-
************************************************************************
*                                                                      *
              Breaking type variable cycles
*                                                                      *
************************************************************************
-}

-- | Conditionally replace all type family applications in the RHS with fresh
-- variables, emitting givens that relate the type family application to the
-- variable. See Note [Type equality cycles] in GHC.Tc.Solver.Canonical.
-- This only works under conditions as described in the Note; otherwise, returns
-- Nothing.
breakTyEqCycle_maybe :: CtEvidence
                     -> CheckTyEqResult   -- result of checkTypeEq
                     -> CanEqLHS
                     -> TcType     -- RHS
                     -> TcS (Maybe ReductionN)
                         -- new RHS that doesn't have any type families
breakTyEqCycle_maybe (ctLocOrigin . ctEvLoc -> CycleBreakerOrigin _) _ _ _
  -- see Detail (7) of Note
  = return Nothing

breakTyEqCycle_maybe ev cte_result lhs rhs
  | NomEq <- eq_rel

  , cte_result `cterHasOnlyProblem` cteSolubleOccurs
     -- only do this if the only problem is a soluble occurs-check
     -- See Detail (8) of the Note.

  = do { should_break <- final_check
       ; mapM go should_break }
  where
    flavour = ctEvFlavour ev
    eq_rel  = ctEvEqRel ev

    final_check = case flavour of
      Given  -> return $ Just rhs
      Wanted    -- Wanteds work only with a touchable tyvar on the left
                -- See "Wanted" section of the Note.
        | TyVarLHS lhs_tv <- lhs ->
          do { (result, rhs) <- touchabilityTest Wanted lhs_tv rhs
             ; return $ case result of
                          Untouchable -> Nothing
                          _           -> Just rhs }
        | otherwise -> return Nothing

    -- This could be considerably more efficient. See Detail (5) of Note.
    go :: TcType -> TcS ReductionN
    go ty | Just ty' <- rewriterView ty = go ty'
    go (Rep.TyConApp tc tys)
      | isTypeFamilyTyCon tc  -- worried about whether this type family is not actually
                              -- causing trouble? See Detail (5) of Note.
      = do { let (fun_args, extra_args) = splitAt (tyConArity tc) tys
                 fun_app                = mkTyConApp tc fun_args
                 fun_app_kind           = typeKind fun_app
           ; fun_redn <- emit_work fun_app_kind fun_app
           ; arg_redns <- unzipRedns <$> mapM go extra_args
           ; return $ mkAppRedns fun_redn arg_redns }
              -- Worried that this substitution will change kinds?
              -- See Detail (3) of Note

      | otherwise
      = do { arg_redns <- unzipRedns <$> mapM go tys
           ; return $ mkTyConAppRedn Nominal tc arg_redns }

    go (Rep.AppTy ty1 ty2)
      = mkAppRedn <$> go ty1 <*> go ty2
    go (Rep.FunTy vis w arg res)
      = mkFunRedn Nominal vis <$> go w <*> go arg <*> go res
    go (Rep.CastTy ty cast_co)
      = mkCastRedn1 Nominal ty cast_co <$> go ty
    go ty@(Rep.TyVarTy {})    = skip ty
    go ty@(Rep.LitTy {})      = skip ty
    go ty@(Rep.ForAllTy {})   = skip ty  -- See Detail (1) of Note
    go ty@(Rep.CoercionTy {}) = skip ty  -- See Detail (2) of Note

    skip ty = return $ mkReflRedn Nominal ty

    emit_work :: TcKind         -- of the function application
              -> TcType         -- original function application
              -> TcS ReductionN -- rewritten type (the fresh tyvar)
    emit_work fun_app_kind fun_app = case flavour of
      Given ->
        do { new_tv <- wrapTcS (TcM.newCycleBreakerTyVar fun_app_kind)
           ; let new_ty     = mkTyVarTy new_tv
                 given_pred = mkHeteroPrimEqPred fun_app_kind fun_app_kind
                                                 fun_app new_ty
                 given_term = evCoercion $ mkNomReflCo new_ty  -- See Detail (4) of Note
           ; new_given <- newGivenEvVar new_loc (given_pred, given_term)
           ; traceTcS "breakTyEqCycle replacing type family in Given" (ppr new_given)
           ; emitWorkNC [new_given]
           ; updInertTcS $ \is ->
               is { inert_cycle_breakers = insertCycleBreakerBinding new_tv fun_app
                                             (inert_cycle_breakers is) }
           ; return $ mkReflRedn Nominal new_ty }
                -- Why reflexive? See Detail (4) of the Note

      Wanted ->
        do { new_tv <- wrapTcS (TcM.newFlexiTyVar fun_app_kind)
           ; let new_ty = mkTyVarTy new_tv
           ; co <- emitNewWantedEq new_loc (ctEvRewriters ev) Nominal new_ty fun_app
           ; return $ mkReduction (mkSymCo co) new_ty }

      -- See Detail (7) of the Note
    new_loc = updateCtLocOrigin (ctEvLoc ev) CycleBreakerOrigin

-- does not fit scenario from Note
breakTyEqCycle_maybe _ _ _ _ = return Nothing

-- | Fill in CycleBreakerTvs with the variables they stand for.
-- See Note [Type equality cycles] in GHC.Tc.Solver.Canonical.
restoreTyVarCycles :: InertSet -> TcM ()
restoreTyVarCycles is
  = forAllCycleBreakerBindings_ (inert_cycle_breakers is) TcM.writeMetaTyVar
{-# SPECIALISE forAllCycleBreakerBindings_ ::
      CycleBreakerVarStack -> (TcTyVar -> TcType -> TcM ()) -> TcM () #-}

-- Unwrap a type synonym only when either:
--   The type synonym is forgetful, or
--   the type synonym mentions a type family in its expansion
-- See Note [Rewriting synonyms] in GHC.Tc.Solver.Rewrite.
rewriterView :: TcType -> Maybe TcType
rewriterView ty@(Rep.TyConApp tc _)
  | isForgetfulSynTyCon tc || (isTypeSynonymTyCon tc && not (isFamFreeTyCon tc))
  = coreView ty
rewriterView _other = Nothing
