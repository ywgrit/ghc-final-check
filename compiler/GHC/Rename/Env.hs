
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeApplications #-}

{-
(c) The GRASP/AQUA Project, Glasgow University, 1992-2006

GHC.Rename.Env contains functions which convert RdrNames into Names.

-}

module GHC.Rename.Env (
        newTopSrcBinder,

        lookupLocatedTopBndrRn, lookupLocatedTopBndrRnN, lookupTopBndrRn,
        lookupLocatedTopConstructorRn, lookupLocatedTopConstructorRnN,

        lookupLocatedOccRn, lookupLocatedOccRnConstr, lookupLocatedOccRnRecField,
        lookupLocatedOccRnNone,
        lookupOccRn, lookupOccRn_maybe,
        lookupLocalOccRn_maybe, lookupInfoOccRn,
        lookupLocalOccThLvl_maybe, lookupLocalOccRn,
        lookupTypeOccRn,
        lookupGlobalOccRn, lookupGlobalOccRn_maybe,

        AmbiguousResult(..),
        lookupExprOccRn,
        lookupRecFieldOcc,
        lookupRecFieldOcc_update,

        ChildLookupResult(..),
        lookupSubBndrOcc_helper,
        combineChildLookupResult, -- Called by lookupChildrenExport

        HsSigCtxt(..), lookupLocalTcNames, lookupSigOccRn, lookupSigOccRnN,
        lookupSigCtxtOccRn, lookupSigCtxtOccRnN,

        lookupInstDeclBndr, lookupFamInstName,
        lookupConstructorFields,

        lookupGreAvailRn,

        -- Rebindable Syntax
        lookupSyntax, lookupSyntaxExpr, lookupSyntaxNames,
        lookupSyntaxName,
        lookupIfThenElse,

        -- QualifiedDo
        lookupQualifiedDoExpr, lookupQualifiedDo,
        lookupQualifiedDoName, lookupNameWithQualifier,

        -- Constructing usage information
        addUsedGRE, addUsedGREs, addUsedDataCons,



        dataTcOccs, --TODO: Move this somewhere, into utils?

    ) where

import GHC.Prelude

import GHC.Iface.Load   ( loadInterfaceForName, loadSrcInterface_maybe )
import GHC.Iface.Env
import GHC.Hs
import GHC.Types.Name.Reader
import GHC.Tc.Errors.Types
import GHC.Tc.Utils.Env
import GHC.Tc.Utils.Monad
import GHC.Parser.PostProcess ( setRdrNameSpace )
import GHC.Builtin.Types
import GHC.Types.Name
import GHC.Types.Name.Set
import GHC.Types.Name.Env
import GHC.Types.Avail
import GHC.Types.Hint
import GHC.Types.Error
import GHC.Unit.Module
import GHC.Unit.Module.ModIface
import GHC.Unit.Module.Warnings  ( WarningTxt )
import GHC.Core.ConLike
import GHC.Core.DataCon
import GHC.Core.TyCon
import GHC.Builtin.Names( rOOT_MAIN )
import GHC.Types.Basic  ( TopLevelFlag(..), TupleSort(..) )
import GHC.Types.SrcLoc as SrcLoc
import GHC.Utils.Outputable as Outputable
import GHC.Types.Unique.Set ( uniqSetAny )
import GHC.Utils.Misc
import GHC.Utils.Panic
import GHC.Data.Maybe
import GHC.Driver.Session
import GHC.Data.FastString
import Control.Monad
import GHC.Data.List.SetOps ( minusList )
import qualified GHC.LanguageExtensions as LangExt
import GHC.Rename.Unbound
import GHC.Rename.Utils
import qualified Data.Semigroup as Semi
import Data.Either      ( partitionEithers )
import Data.List        ( find )
import qualified Data.List.NonEmpty as NE
import Control.Arrow    ( first )
import GHC.Types.FieldLabel
import GHC.Data.Bag
import GHC.Types.PkgQual
import Language.Haskell.Syntax.Basic (FieldLabelString(..))

{-
*********************************************************
*                                                      *
                Source-code binders
*                                                      *
*********************************************************

Note [Signature lazy interface loading]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

GHC's lazy interface loading can be a bit confusing, so this Note is an
empirical description of what happens in one interesting case. When
compiling a signature module against an its implementation, we do NOT
load interface files associated with its names until after the type
checking phase.  For example:

    module ASig where
        data T
        f :: T -> T

Suppose we compile this with -sig-of "A is ASig":

    module B where
        data T = T
        f T = T

    module A(module B) where
        import B

During type checking, we'll load A.hi because we need to know what the
RdrEnv for the module is, but we DO NOT load the interface for B.hi!
It's wholly unnecessary: our local definition 'data T' in ASig is all
the information we need to finish type checking.  This is contrast to
type checking of ordinary Haskell files, in which we would not have the
local definition "data T" and would need to consult B.hi immediately.
(Also, this situation never occurs for hs-boot files, since you're not
allowed to reexport from another module.)

After type checking, we then check that the types we provided are
consistent with the backing implementation (in checkHiBootOrHsigIface).
At this point, B.hi is loaded, because we need something to compare
against.

I discovered this behavior when trying to figure out why type class
instances for Data.Map weren't in the EPS when I was type checking a
test very much like ASig (sigof02dm): the associated interface hadn't
been loaded yet!  (The larger issue is a moot point, since an instance
declared in a signature can never be a duplicate.)

This behavior might change in the future.  Consider this
alternate module B:

    module B where
        {-# DEPRECATED T, f "Don't use" #-}
        data T = T
        f T = T

One might conceivably want to report deprecation warnings when compiling
ASig with -sig-of B, in which case we need to look at B.hi to find the
deprecation warnings during renaming.  At the moment, you don't get any
warning until you use the identifier further downstream.  This would
require adjusting addUsedGRE so that during signature compilation,
we do not report deprecation warnings for LocalDef.  See also
Note [Handling of deprecations]
-}

newTopSrcBinder :: LocatedN RdrName -> RnM Name
newTopSrcBinder (L loc rdr_name)
  | Just name <- isExact_maybe rdr_name
  =     -- This is here to catch
        --   (a) Exact-name binders created by Template Haskell
        --   (b) The PrelBase defn of (say) [] and similar, for which
        --       the parser reads the special syntax and returns an Exact RdrName
        -- We are at a binding site for the name, so check first that it
        -- the current module is the correct one; otherwise GHC can get
        -- very confused indeed. This test rejects code like
        --      data T = (,) Int Int
        -- unless we are in GHC.Tup
    if isExternalName name then
      do { this_mod <- getModule
         ; unless (this_mod == nameModule name)
                  (addErrAt (locA loc) (badOrigBinding rdr_name))
         ; return name }
    else   -- See Note [Binders in Template Haskell] in "GHC.ThToHs"
      do { this_mod <- getModule
         ; externaliseName this_mod name }

  | Just (rdr_mod, rdr_occ) <- isOrig_maybe rdr_name
  = do  { this_mod <- getModule
        ; unless (rdr_mod == this_mod || rdr_mod == rOOT_MAIN)
                 (addErrAt (locA loc) (badOrigBinding rdr_name))
        -- When reading External Core we get Orig names as binders,
        -- but they should agree with the module gotten from the monad
        --
        -- We can get built-in syntax showing up here too, sadly.  If you type
        --      data T = (,,,)
        -- the constructor is parsed as a type, and then GHC.Parser.PostProcess.tyConToDataCon
        -- uses setRdrNameSpace to make it into a data constructors.  At that point
        -- the nice Exact name for the TyCon gets swizzled to an Orig name.
        -- Hence the badOrigBinding error message.
        --

        -- MP 2022: I suspect this code path is never called for `rOOT_MAIN` anymore
        -- because External Core has been removed but we instead have some similar logic for
        -- serialising whole programs into interface files in GHC.IfaceToCore.mk_top_id.

        -- Except for the ":Main.main = ..." definition inserted into
        -- the Main module; ugh!

        -- Because of this latter case, we call newGlobalBinder with a module from
        -- the RdrName, not from the environment.  In principle, it'd be fine to
        -- have an arbitrary mixture of external core definitions in a single module,
        -- (apart from module-initialisation issues, perhaps).
        ; newGlobalBinder rdr_mod rdr_occ (locA loc) }

  | otherwise
  = do  { when (isQual rdr_name)
                 (addErrAt (locA loc) (badQualBndrErr rdr_name))
                -- Binders should not be qualified; if they are, and with a different
                -- module name, we get a confusing "M.T is not in scope" error later

        ; stage <- getStage
        ; if isBrackStage stage then
                -- We are inside a TH bracket, so make an *Internal* name
                -- See Note [Top-level Names in Template Haskell decl quotes] in GHC.Rename.Names
             do { uniq <- newUnique
                ; return (mkInternalName uniq (rdrNameOcc rdr_name) (locA loc)) }
          else
             do { this_mod <- getModule
                ; traceRn "newTopSrcBinder" (ppr this_mod $$ ppr rdr_name $$ ppr (locA loc))
                ; newGlobalBinder this_mod (rdrNameOcc rdr_name) (locA loc) }
        }

{-
*********************************************************
*                                                      *
        Source code occurrences
*                                                      *
*********************************************************

Looking up a name in the GHC.Rename.Env.

Note [Type and class operator definitions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We want to reject all of these unless we have -XTypeOperators (#3265)
   data a :*: b  = ...
   class a :*: b where ...
   data (:*:) a b  = ....
   class (:*:) a b where ...
The latter two mean that we are not just looking for a
*syntactically-infix* declaration, but one that uses an operator
OccName.  We use OccName.isSymOcc to detect that case, which isn't
terribly efficient, but there seems to be no better way.
-}

-- Can be made to not be exposed
-- Only used unwrapped in rnAnnProvenance
lookupTopBndrRn :: WhatLooking -> RdrName -> RnM Name
-- Look up a top-level source-code binder.   We may be looking up an unqualified 'f',
-- and there may be several imported 'f's too, which must not confuse us.
-- For example, this is OK:
--      import Foo( f )
--      infix 9 f       -- The 'f' here does not need to be qualified
--      f x = x         -- Nor here, of course
-- So we have to filter out the non-local ones.
--
-- A separate function (importsFromLocalDecls) reports duplicate top level
-- decls, so here it's safe just to choose an arbitrary one.
lookupTopBndrRn which_suggest rdr_name =
  lookupExactOrOrig rdr_name id $
    do  {  -- Check for operators in type or class declarations
           -- See Note [Type and class operator definitions]
          let occ = rdrNameOcc rdr_name
        ; when (isTcOcc occ && isSymOcc occ)
               (do { op_ok <- xoptM LangExt.TypeOperators
                   ; unless op_ok (addErr (TcRnIllegalTypeOperatorDecl rdr_name)) })

        ; env <- getGlobalRdrEnv
        ; case filter isLocalGRE (lookupGRE_RdrName rdr_name env) of
            [gre] -> return (greMangledName gre)
            _     -> do -- Ambiguous (can't happen) or unbound
                        traceRn "lookupTopBndrRN fail" (ppr rdr_name)
                        unboundName (LF which_suggest WL_LocalTop) rdr_name
    }

lookupLocatedTopConstructorRn :: Located RdrName -> RnM (Located Name)
lookupLocatedTopConstructorRn = wrapLocM (lookupTopBndrRn WL_Constructor)

lookupLocatedTopConstructorRnN :: LocatedN RdrName -> RnM (LocatedN Name)
lookupLocatedTopConstructorRnN = wrapLocMA (lookupTopBndrRn WL_Constructor)

lookupLocatedTopBndrRn :: Located RdrName -> RnM (Located Name)
lookupLocatedTopBndrRn = wrapLocM (lookupTopBndrRn WL_Anything)

lookupLocatedTopBndrRnN :: LocatedN RdrName -> RnM (LocatedN Name)
lookupLocatedTopBndrRnN = wrapLocMA (lookupTopBndrRn WL_Anything)

-- | Lookup an @Exact@ @RdrName@. See Note [Looking up Exact RdrNames].
-- This never adds an error, but it may return one, see
-- Note [Errors in lookup functions]
lookupExactOcc_either :: Name -> RnM (Either NotInScopeError Name)
lookupExactOcc_either name
  | Just thing <- wiredInNameTyThing_maybe name
  , Just tycon <- case thing of
                    ATyCon tc                 -> Just tc
                    AConLike (RealDataCon dc) -> Just (dataConTyCon dc)
                    _                         -> Nothing
  , Just tupleSort <- tyConTuple_maybe tycon
  = do { let tupArity = case tupleSort of
               -- Unboxed tuples have twice as many arguments because of the
               -- 'RuntimeRep's (#17837)
               UnboxedTuple -> tyConArity tycon `div` 2
               _ -> tyConArity tycon
       ; checkTupSize tupArity
       ; return (Right name) }

  | isExternalName name
  = return (Right name)

  | otherwise
  = do { env <- getGlobalRdrEnv
       ; let -- See Note [Splicing Exact names]
             main_occ =  nameOccName name
             demoted_occs = case demoteOccName main_occ of
                              Just occ -> [occ]
                              Nothing  -> []
             gres = [ gre | occ <- main_occ : demoted_occs
                          , gre <- lookupGlobalRdrEnv env occ
                          , greMangledName gre == name ]
       ; case gres of
           [gre] -> return (Right (greMangledName gre))

           []    -> -- See Note [Splicing Exact names]
                    do { lcl_env <- getLocalRdrEnv
                       ; if name `inLocalRdrEnvScope` lcl_env
                         then return (Right name)
                         else
                         do { th_topnames_var <- fmap tcg_th_topnames getGblEnv
                            ; th_topnames <- readTcRef th_topnames_var
                            ; if name `elemNameSet` th_topnames
                              then return (Right name)
                              else return (Left (NoExactName name))
                            }
                       }

           gres -> return (Left (SameName gres)) -- Ugh!  See Note [Template Haskell ambiguity]
       }

-----------------------------------------------
lookupInstDeclBndr :: Name -> SDoc -> RdrName -> RnM Name
-- This is called on the method name on the left-hand side of an
-- instance declaration binding. eg.  instance Functor T where
--                                       fmap = ...
--                                       ^^^^ called on this
-- Regardless of how many unqualified fmaps are in scope, we want
-- the one that comes from the Functor class.
--
-- Furthermore, note that we take no account of whether the
-- name is only in scope qualified.  I.e. even if method op is
-- in scope as M.op, we still allow plain 'op' on the LHS of
-- an instance decl
--
-- The "what" parameter says "method" or "associated type",
-- depending on what we are looking up
lookupInstDeclBndr cls what rdr
  = do { when (isQual rdr)
              (addErr (badQualBndrErr rdr))
                -- In an instance decl you aren't allowed
                -- to use a qualified name for the method
                -- (Although it'd make perfect sense.)
       ; mb_name <- lookupSubBndrOcc
                          False -- False => we don't give deprecated
                                -- warnings when a deprecated class
                                -- method is defined. We only warn
                                -- when it's used
                          cls doc rdr
       ; case mb_name of
           Left err -> do { addErr (mkTcRnNotInScope rdr err)
                          ; return (mkUnboundNameRdr rdr) }
           Right nm -> return nm }
  where
    doc = what <+> text "of class" <+> quotes (ppr cls)

-----------------------------------------------
lookupFamInstName :: Maybe Name -> LocatedN RdrName
                  -> RnM (LocatedN Name)
-- Used for TyData and TySynonym family instances only,
-- See Note [Family instance binders]
lookupFamInstName (Just cls) tc_rdr  -- Associated type; c.f GHC.Rename.Bind.rnMethodBind
  = wrapLocMA (lookupInstDeclBndr cls (text "associated type")) tc_rdr
lookupFamInstName Nothing tc_rdr     -- Family instance; tc_rdr is an *occurrence*
  = lookupLocatedOccRnConstr tc_rdr

-----------------------------------------------
lookupConstructorFields :: Name -> RnM [FieldLabel]
-- Look up the fields of a given constructor
--   *  For constructors from this module, use the record field env,
--      which is itself gathered from the (as yet un-typechecked)
--      data type decls
--
--    * For constructors from imported modules, use the *type* environment
--      since imported modules are already compiled, the info is conveniently
--      right there

lookupConstructorFields con_name
  = do  { this_mod <- getModule
        ; if nameIsLocalOrFrom this_mod con_name then
          do { field_env <- getRecFieldEnv
             ; traceTc "lookupCF" (ppr con_name $$ ppr (lookupNameEnv field_env con_name) $$ ppr field_env)
             ; return (lookupNameEnv field_env con_name `orElse` []) }
          else
          do { con <- tcLookupConLike con_name
             ; traceTc "lookupCF 2" (ppr con)
             ; return (conLikeFieldLabels con) } }


-- In CPS style as `RnM r` is monadic
-- Reports an error if the name is an Exact or Orig and it can't find the name
-- Otherwise if it is not an Exact or Orig, returns k
lookupExactOrOrig :: RdrName -> (Name -> r) -> RnM r -> RnM r
lookupExactOrOrig rdr_name res k
  = do { men <- lookupExactOrOrig_base rdr_name
       ; case men of
          FoundExactOrOrig n -> return (res n)
          ExactOrOrigError e ->
            do { addErr (mkTcRnNotInScope rdr_name e)
               ; return (res (mkUnboundNameRdr rdr_name)) }
          NotExactOrOrig     -> k }

-- Variant of 'lookupExactOrOrig' that does not report an error
-- See Note [Errors in lookup functions]
-- Calls k if the name is neither an Exact nor Orig
lookupExactOrOrig_maybe :: RdrName -> (Maybe Name -> r) -> RnM r -> RnM r
lookupExactOrOrig_maybe rdr_name res k
  = do { men <- lookupExactOrOrig_base rdr_name
       ; case men of
           FoundExactOrOrig n -> return (res (Just n))
           ExactOrOrigError _ -> return (res Nothing)
           NotExactOrOrig     -> k }

data ExactOrOrigResult = FoundExactOrOrig Name -- ^ Found an Exact Or Orig Name
                       | ExactOrOrigError NotInScopeError -- ^ The RdrName was an Exact
                                                          -- or Orig, but there was an
                                                          -- error looking up the Name
                       | NotExactOrOrig -- ^ The RdrName is neither an Exact nor
                                        -- Orig

-- Does the actual looking up an Exact or Orig name, see 'ExactOrOrigResult'
lookupExactOrOrig_base :: RdrName -> RnM ExactOrOrigResult
lookupExactOrOrig_base rdr_name
  | Just n <- isExact_maybe rdr_name   -- This happens in derived code
  = cvtEither <$> lookupExactOcc_either n
  | Just (rdr_mod, rdr_occ) <- isOrig_maybe rdr_name
  = FoundExactOrOrig <$> lookupOrig rdr_mod rdr_occ
  | otherwise = return NotExactOrOrig
  where
    cvtEither (Left e)  = ExactOrOrigError e
    cvtEither (Right n) = FoundExactOrOrig n


{- Note [Errors in lookup functions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Many of these lookup functions will attach an error if it can't find the Name it
is trying to lookup. However there are also _maybe and _either variants for many
of these functions.

These variants should *not* attach any errors, as there are
places where we want to attempt looking up a name, but it's not the end of the
world if we don't find it.

For example, see lookupThName_maybe: It calls lookupOccRn_maybe multiple
times for varying names in different namespaces. lookupOccRn_maybe should
therefore never attach an error, instead just return a Nothing.

For these _maybe/_either variant functions then, avoid calling further lookup
functions that can attach errors and instead call their _maybe/_either
counterparts.
-}

-----------------------------------------------
-- | Look up an occurrence of a field in record construction or pattern
-- matching (but not update).  When the -XDisambiguateRecordFields
-- flag is on, take account of the data constructor name to
-- disambiguate which field to use.
--
-- See Note [DisambiguateRecordFields] and Note [NoFieldSelectors].
lookupRecFieldOcc :: Maybe Name -- Nothing  => just look it up as usual
                                -- Just con => use data con to disambiguate
                  -> RdrName
                  -> RnM Name
lookupRecFieldOcc mb_con rdr_name
  | Just con <- mb_con
  , isUnboundName con  -- Avoid error cascade
  = return (mkUnboundNameRdr rdr_name)
  | Just con <- mb_con
  = lookupExactOrOrig rdr_name id $  -- See Note [Record field names and Template Haskell]
    do { flds <- lookupConstructorFields con
       ; env <- getGlobalRdrEnv
       ; let lbl      = FieldLabelString $ occNameFS (rdrNameOcc rdr_name)
             mb_field = do fl <- find ((== lbl) . flLabel) flds
                           -- We have the label, now check it is in scope.  If
                           -- there is a qualifier, use pickGREs to check that
                           -- the qualifier is correct, and return the filtered
                           -- GRE so we get import usage right (see #17853).
                           gre <- lookupGRE_FieldLabel env fl
                           if isQual rdr_name
                             then do gre' <- listToMaybe (pickGREs rdr_name [gre])
                                     return (fl, gre')
                              else return (fl, gre)
       ; case mb_field of
           Just (fl, gre) -> do { addUsedGRE True gre
                                ; return (flSelector fl) }
           Nothing        -> do { addErr (badFieldConErr con lbl)
                                ; return (mkUnboundNameRdr rdr_name) } }

  | otherwise  -- Can't use the data constructor to disambiguate
  = lookupGlobalOccRn' WantBoth rdr_name
    -- This use of Global is right as we are looking up a selector,
    -- which can only be defined at the top level.

-- | Look up an occurrence of a field in a record update, returning the selector
-- name.
--
-- Unlike construction and pattern matching with @-XDisambiguateRecordFields@
-- (see 'lookupRecFieldOcc'), there is no data constructor to help disambiguate,
-- so this may be ambiguous if the field is in scope multiple times.  However we
-- ignore non-fields in scope with the same name if @-XDisambiguateRecordFields@
-- is on (see Note [DisambiguateRecordFields for updates]).
--
-- Here a field is in scope even if @NoFieldSelectors@ was enabled at its
-- definition site (see Note [NoFieldSelectors]).
lookupRecFieldOcc_update
  :: DuplicateRecordFields
  -> RdrName
  -> RnM AmbiguousResult
lookupRecFieldOcc_update dup_fields_ok rdr_name = do
    disambig_ok <- xoptM LangExt.DisambiguateRecordFields
    let want | disambig_ok = WantField
             | otherwise   = WantBoth
    mr <- lookupGlobalOccRn_overloaded dup_fields_ok want rdr_name
    case mr of
        Just r  -> return r
        Nothing  -- Try again if we previously looked only for fields, see
                 -- Note [DisambiguateRecordFields for updates]
          | disambig_ok -> do mr' <- lookupGlobalOccRn_overloaded dup_fields_ok WantBoth rdr_name
                              case mr' of
                                  Just r -> return r
                                  Nothing -> unbound
          | otherwise   -> unbound
  where
    unbound = UnambiguousGre . NormalGreName
          <$> unboundName (LF WL_RecField WL_Global) rdr_name


{- Note [DisambiguateRecordFields]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When we are looking up record fields in record construction or pattern
matching, we can take advantage of the data constructor name to
resolve fields that would otherwise be ambiguous (provided the
-XDisambiguateRecordFields flag is on).

For example, consider:

   data S = MkS { x :: Int }
   data T = MkT { x :: Int }

   e = MkS { x = 3 }

When we are renaming the occurrence of `x` in `e`, instead of looking
`x` up directly (and finding both fields), lookupRecFieldOcc will
search the fields of `MkS` to find the only possible `x` the user can
mean.

Of course, we still have to check the field is in scope, using
lookupGRE_FieldLabel.  The handling of qualified imports is slightly
subtle: the occurrence may be unqualified even if the field is
imported only qualified (but if the occurrence is qualified, the
qualifier must be correct). For example:

   module A where
     data S = MkS { x :: Int }
     data T = MkT { x :: Int }

   module B where
     import qualified A (S(..))
     import A (T(MkT))

     e1 = MkT   { x = 3 }   -- x not in scope, so fail
     e2 = A.MkS { B.x = 3 } -- module qualifier is wrong, so fail
     e3 = A.MkS { x = 3 }   -- x in scope (lack of module qualifier permitted)

In case `e1`, lookupGRE_FieldLabel will return Nothing.  In case `e2`,
lookupGRE_FieldLabel will return the GRE for `A.x`, but then the guard
will fail because the field RdrName `B.x` is qualified and pickGREs
rejects the GRE.  In case `e3`, lookupGRE_FieldLabel will return the
GRE for `A.x` and the guard will succeed because the field RdrName `x`
is unqualified.


Note [DisambiguateRecordFields for updates]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When we are looking up record fields in record update, we can take advantage of
the fact that we know we are looking for a field, even though we do not know the
data constructor name (as in Note [DisambiguateRecordFields]), provided the
-XDisambiguateRecordFields flag is on.

For example, consider:

   module N where
     f = ()

   {-# LANGUAGE DisambiguateRecordFields #-}
   module M where
     import N (f)
     data T = MkT { f :: Int }
     t = MkT { f = 1 }  -- unambiguous because MkT determines which field we mean
     u = t { f = 2 }    -- unambiguous because we ignore the non-field 'f'

This works by lookupRecFieldOcc_update using 'WantField :: FieldsOrSelectors'
when looking up the field name, so that 'filterFieldGREs' will later ignore any
non-fields in scope.  Of course, if a record update has two fields in scope with
the same name, it is still ambiguous.

If we do not find anything when looking only for fields, we try again allowing
fields or non-fields.  This leads to a better error message if the user
mistakenly tries to use a non-field name in a record update:

    f = ()
    e x = x { f = () }

Unlike with constructors or pattern-matching, we do not allow the module
qualifier to be omitted, because we do not have a data constructor from which to
determine it.

Note [Record field names and Template Haskell]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider (#12130):

   module Foo where
     import M
     b = $(funny)

   module M(funny) where
     data T = MkT { x :: Int }
     funny :: Q Exp
     funny = [| MkT { x = 3 } |]

When we splice, `MkT` is not lexically in scope, so
lookupGRE_FieldLabel will fail.  But there is no need for
disambiguation anyway, because `x` is an original name, and
lookupGlobalOccRn will find it.
-}


-- | Used in export lists to lookup the children.
lookupSubBndrOcc_helper :: Bool -> Bool -> Name -> RdrName
                        -> RnM ChildLookupResult
lookupSubBndrOcc_helper must_have_parent warn_if_deprec parent rdr_name
  | isUnboundName parent
    -- Avoid an error cascade
  = return (FoundChild NoParent (NormalGreName (mkUnboundNameRdr rdr_name)))

  | otherwise = do
  gre_env <- getGlobalRdrEnv

  let original_gres = lookupGlobalRdrEnv gre_env (rdrNameOcc rdr_name)
  -- Disambiguate the lookup based on the parent information.
  -- The remaining GREs are things that we *could* export here, note that
  -- this includes things which have `NoParent`. Those are sorted in
  -- `checkPatSynParent`.
  traceRn "parent" (ppr parent)
  traceRn "lookupExportChild original_gres:" (ppr original_gres)
  traceRn "lookupExportChild picked_gres:" (ppr (picked_gres original_gres) $$ ppr must_have_parent)
  case picked_gres original_gres of
    NoOccurrence ->
      noMatchingParentErr original_gres
    UniqueOccurrence g ->
      if must_have_parent then noMatchingParentErr original_gres
                          else checkFld g
    DisambiguatedOccurrence g ->
      checkFld g
    AmbiguousOccurrence gres ->
      mkNameClashErr gres
    where
        -- Convert into FieldLabel if necessary
        checkFld :: GlobalRdrElt -> RnM ChildLookupResult
        checkFld g@GRE{gre_name,gre_par} = do
          addUsedGRE warn_if_deprec g
          return $ FoundChild gre_par gre_name

        -- Called when we find no matching GREs after disambiguation but
        -- there are three situations where this happens.
        -- 1. There were none to begin with.
        -- 2. None of the matching ones were the parent but
        --  a. They were from an overloaded record field so we can report
        --     a better error
        --  b. The original lookup was actually ambiguous.
        --     For example, the case where overloading is off and two
        --     record fields are in scope from different record
        --     constructors, neither of which is the parent.
        noMatchingParentErr :: [GlobalRdrElt] -> RnM ChildLookupResult
        noMatchingParentErr original_gres = do
          traceRn "npe" (ppr original_gres)
          dup_fields_ok <- xoptM LangExt.DuplicateRecordFields
          case original_gres of
            [] ->  return NameNotFound
            [g] -> return $ IncorrectParent parent
                              (gre_name g)
                              [p | Just p <- [getParent g]]
            gss@(g:gss'@(_:_)) ->
              if all isRecFldGRE gss && dup_fields_ok
                then return $
                      IncorrectParent parent
                        (gre_name g)
                        [p | x <- gss, Just p <- [getParent x]]
                else mkNameClashErr $ g NE.:| gss'

        mkNameClashErr :: NE.NonEmpty GlobalRdrElt -> RnM ChildLookupResult
        mkNameClashErr gres = do
          addNameClashErrRn rdr_name gres
          return (FoundChild (gre_par (NE.head gres)) (gre_name (NE.head gres)))

        getParent :: GlobalRdrElt -> Maybe Name
        getParent (GRE { gre_par = p } ) =
          case p of
            ParentIs cur_parent -> Just cur_parent
            NoParent -> Nothing

        picked_gres :: [GlobalRdrElt] -> DisambigInfo
        -- For Unqual, find GREs that are in scope qualified or unqualified
        -- For Qual,   find GREs that are in scope with that qualification
        picked_gres gres
          | isUnqual rdr_name
          = mconcat (map right_parent gres)
          | otherwise
          = mconcat (map right_parent (pickGREs rdr_name gres))

        right_parent :: GlobalRdrElt -> DisambigInfo
        right_parent p
          = case getParent p of
               Just cur_parent
                  | parent == cur_parent -> DisambiguatedOccurrence p
                  | otherwise            -> NoOccurrence
               Nothing                   -> UniqueOccurrence p


-- This domain specific datatype is used to record why we decided it was
-- possible that a GRE could be exported with a parent.
data DisambigInfo
       = NoOccurrence
          -- The GRE could never be exported. It has the wrong parent.
       | UniqueOccurrence GlobalRdrElt
          -- The GRE has no parent. It could be a pattern synonym.
       | DisambiguatedOccurrence GlobalRdrElt
          -- The parent of the GRE is the correct parent
       | AmbiguousOccurrence (NE.NonEmpty GlobalRdrElt)
          -- For example, two normal identifiers with the same name are in
          -- scope. They will both be resolved to "UniqueOccurrence" and the
          -- monoid will combine them to this failing case.

instance Outputable DisambigInfo where
  ppr NoOccurrence = text "NoOccurrence"
  ppr (UniqueOccurrence gre) = text "UniqueOccurrence:" <+> ppr gre
  ppr (DisambiguatedOccurrence gre) = text "DiambiguatedOccurrence:" <+> ppr gre
  ppr (AmbiguousOccurrence gres)    = text "Ambiguous:" <+> ppr gres

instance Semi.Semigroup DisambigInfo where
  -- This is the key line: We prefer disambiguated occurrences to other
  -- names.
  _ <> DisambiguatedOccurrence g' = DisambiguatedOccurrence g'
  DisambiguatedOccurrence g' <> _ = DisambiguatedOccurrence g'

  NoOccurrence <> m = m
  m <> NoOccurrence = m
  UniqueOccurrence g <> UniqueOccurrence g'
    = AmbiguousOccurrence $ g NE.:| [g']
  UniqueOccurrence g <> AmbiguousOccurrence gs
    = AmbiguousOccurrence (g `NE.cons` gs)
  AmbiguousOccurrence gs <> UniqueOccurrence g'
    = AmbiguousOccurrence (g' `NE.cons` gs)
  AmbiguousOccurrence gs <> AmbiguousOccurrence gs'
    = AmbiguousOccurrence (gs Semi.<> gs')

instance Monoid DisambigInfo where
  mempty = NoOccurrence
  mappend = (Semi.<>)

-- Lookup SubBndrOcc can never be ambiguous
--
-- Records the result of looking up a child.
data ChildLookupResult
      = NameNotFound                --  We couldn't find a suitable name
      | IncorrectParent Name        -- Parent
                        GreName     -- Child we were looking for
                        [Name]      -- List of possible parents
      | FoundChild Parent GreName   --  We resolved to a child

-- | Specialised version of msum for RnM ChildLookupResult
combineChildLookupResult :: [RnM ChildLookupResult] -> RnM ChildLookupResult
combineChildLookupResult [] = return NameNotFound
combineChildLookupResult (x:xs) = do
  res <- x
  case res of
    NameNotFound -> combineChildLookupResult xs
    _ -> return res

instance Outputable ChildLookupResult where
  ppr NameNotFound = text "NameNotFound"
  ppr (FoundChild p n) = text "Found:" <+> ppr p <+> ppr n
  ppr (IncorrectParent p n ns) = text "IncorrectParent"
                                  <+> hsep [ppr p, ppr n, ppr ns]

lookupSubBndrOcc :: Bool
                 -> Name     -- Parent
                 -> SDoc
                 -> RdrName
                 -> RnM (Either NotInScopeError Name)
-- Find all the things the rdr-name maps to
-- and pick the one with the right parent name
lookupSubBndrOcc warn_if_deprec the_parent doc rdr_name = do
  res <-
    lookupExactOrOrig rdr_name (FoundChild NoParent . NormalGreName) $
      -- This happens for built-in classes, see mod052 for example
      lookupSubBndrOcc_helper True warn_if_deprec the_parent rdr_name
  case res of
    NameNotFound -> return (Left (UnknownSubordinate doc))
    FoundChild _p child -> return (Right (greNameMangledName child))
    IncorrectParent {}
         -- See [Mismatched class methods and associated type families]
         -- in TcInstDecls.
      -> return $ Left (UnknownSubordinate doc)

{-
Note [Family instance binders]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider
  data family F a
  data instance F T = X1 | X2

The 'data instance' decl has an *occurrence* of F (and T), and *binds*
X1 and X2.  (This is unlike a normal data type declaration which would
bind F too.)  So we want an AvailTC F [X1,X2].

Now consider a similar pair:
  class C a where
    data G a
  instance C S where
    data G S = Y1 | Y2

The 'data G S' *binds* Y1 and Y2, and has an *occurrence* of G.

But there is a small complication: in an instance decl, we don't use
qualified names on the LHS; instead we use the class to disambiguate.
Thus:
  module M where
    import Blib( G )
    class C a where
      data G a
    instance C S where
      data G S = Y1 | Y2
Even though there are two G's in scope (M.G and Blib.G), the occurrence
of 'G' in the 'instance C S' decl is unambiguous, because C has only
one associated type called G. This is exactly what happens for methods,
and it is only consistent to do the same thing for types. That's the
role of the function lookupTcdName; the (Maybe Name) give the class of
the enclosing instance decl, if any.

Note [Looking up Exact RdrNames]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Exact RdrNames are generated by:

* Template Haskell (See Note [Binders in Template Haskell] in GHC.ThToHs)
* Derived instances (See Note [Auxiliary binders] in GHC.Tc.Deriv.Generate)

For data types and classes have Exact system Names in the binding
positions for constructors, TyCons etc.  For example
    [d| data T = MkT Int |]
when we splice in and convert to HsSyn RdrName, we'll get
    data (Exact (system Name "T")) = (Exact (system Name "MkT")) ...
These System names are generated by GHC.ThToHs.thRdrName

But, constructors and the like need External Names, not System Names!
So we do the following

 * In GHC.Rename.Env.newTopSrcBinder we spot Exact RdrNames that wrap a
   non-External Name, and make an External name for it. This is
   the name that goes in the GlobalRdrEnv

 * When looking up an occurrence of an Exact name, done in
   GHC.Rename.Env.lookupExactOcc, we find the Name with the right unique in the
   GlobalRdrEnv, and use the one from the envt -- it will be an
   External Name in the case of the data type/constructor above.

 * Exact names are also use for purely local binders generated
   by TH, such as    \x_33. x_33
   Both binder and occurrence are Exact RdrNames.  The occurrence
   gets looked up in the LocalRdrEnv by GHC.Rename.Env.lookupOccRn, and
   misses, because lookupLocalRdrEnv always returns Nothing for
   an Exact Name.  Now we fall through to lookupExactOcc, which
   will find the Name is not in the GlobalRdrEnv, so we just use
   the Exact supplied Name.

Note [Splicing Exact names]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider the splice $(do { x <- newName "x"; return (VarE x) })
This will generate a (HsExpr RdrName) term that mentions the
Exact RdrName "x_56" (or whatever), but does not bind it.  So
when looking such Exact names we want to check that it's in scope,
otherwise the type checker will get confused.  To do this we need to
keep track of all the Names in scope, and the LocalRdrEnv does just that;
we consult it with RdrName.inLocalRdrEnvScope.

There is another wrinkle.  With TH and -XDataKinds, consider
   $( [d| data Nat = Zero
          data T = MkT (Proxy 'Zero)  |] )
After splicing, but before renaming we get this:
   data Nat_77{tc} = Zero_78{d}
   data T_79{tc} = MkT_80{d} (Proxy 'Zero_78{tc})  |] )
The occurrence of 'Zero in the data type for T has the right unique,
but it has a TcClsName name-space in its OccName.  (This is set by
the ctxt_ns argument of Convert.thRdrName.)  When we check that is
in scope in the GlobalRdrEnv, we need to look up the DataName namespace
too.  (An alternative would be to make the GlobalRdrEnv also have
a Name -> GRE mapping.)

Note [Template Haskell ambiguity]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The GlobalRdrEnv invariant says that if
  occ -> [gre1, ..., gren]
then the gres have distinct Names (INVARIANT 1 of GlobalRdrEnv).
This is guaranteed by extendGlobalRdrEnvRn (the dups check in add_gre).

So how can we get multiple gres in lookupExactOcc_maybe?  Because in
TH we might use the same TH NameU in two different name spaces.
eg (#7241):
   $(newName "Foo" >>= \o -> return [DataD [] o [] [RecC o []] [''Show]])
Here we generate a type constructor and data constructor with the same
unique, but different name spaces.

It'd be nicer to rule this out in extendGlobalRdrEnvRn, but that would
mean looking up the OccName in every name-space, just in case, and that
seems a bit brutal.  So it's just done here on lookup.  But we might
need to revisit that choice.

Note [Usage for sub-bndrs]
~~~~~~~~~~~~~~~~~~~~~~~~~~
If you have this
   import qualified M( C( f ) )
   instance M.C T where
     f x = x
then is the qualified import M.f used?  Obviously yes.
But the RdrName used in the instance decl is unqualified.  In effect,
we fill in the qualification by looking for f's whose class is M.C
But when adding to the UsedRdrNames we must make that qualification
explicit (saying "used  M.f"), otherwise we get "Redundant import of M.f".

So we make up a suitable (fake) RdrName.  But be careful
   import qualified M
   import M( C(f) )
   instance C T where
     f x = x
Here we want to record a use of 'f', not of 'M.f', otherwise
we'll miss the fact that the qualified import is redundant.

--------------------------------------------------
--              Occurrences
--------------------------------------------------
-}


lookupLocatedOccRn :: GenLocated (SrcSpanAnn' ann) RdrName
                   -> TcRn (GenLocated (SrcSpanAnn' ann) Name)
lookupLocatedOccRn = wrapLocMA lookupOccRn

lookupLocatedOccRnConstr :: GenLocated (SrcSpanAnn' ann) RdrName
                         -> TcRn (GenLocated (SrcSpanAnn' ann) Name)
lookupLocatedOccRnConstr = wrapLocMA lookupOccRnConstr

lookupLocatedOccRnRecField :: GenLocated (SrcSpanAnn' ann) RdrName
                           -> TcRn (GenLocated (SrcSpanAnn' ann) Name)
lookupLocatedOccRnRecField = wrapLocMA lookupOccRnRecField

lookupLocatedOccRnNone :: GenLocated (SrcSpanAnn' ann) RdrName
                       -> TcRn (GenLocated (SrcSpanAnn' ann) Name)
lookupLocatedOccRnNone = wrapLocMA lookupOccRnNone

lookupLocalOccRn_maybe :: RdrName -> RnM (Maybe Name)
-- Just look in the local environment
lookupLocalOccRn_maybe rdr_name
  = do { local_env <- getLocalRdrEnv
       ; return (lookupLocalRdrEnv local_env rdr_name) }

lookupLocalOccThLvl_maybe :: Name -> RnM (Maybe (TopLevelFlag, ThLevel))
-- Just look in the local environment
lookupLocalOccThLvl_maybe name
  = do { lcl_env <- getLclEnv
       ; return (lookupNameEnv (tcl_th_bndrs lcl_env) name) }

-- lookupOccRn' looks up an occurrence of a RdrName, and uses its argument to
-- determine what kind of suggestions should be displayed if it is not in scope
lookupOccRn' :: WhatLooking -> RdrName -> RnM Name
lookupOccRn' which_suggest rdr_name
  = do { mb_name <- lookupOccRn_maybe rdr_name
       ; case mb_name of
           Just name -> return name
           Nothing   -> reportUnboundName' which_suggest rdr_name }

-- lookupOccRn looks up an occurrence of a RdrName and displays suggestions if
-- it is not in scope
lookupOccRn :: RdrName -> RnM Name
lookupOccRn = lookupOccRn' WL_Anything

-- lookupOccRnConstr looks up an occurrence of a RdrName and displays
-- constructors and pattern synonyms as suggestions if it is not in scope
lookupOccRnConstr :: RdrName -> RnM Name
lookupOccRnConstr = lookupOccRn' WL_Constructor

-- lookupOccRnRecField looks up an occurrence of a RdrName and displays
-- record fields as suggestions if it is not in scope
lookupOccRnRecField :: RdrName -> RnM Name
lookupOccRnRecField = lookupOccRn' WL_RecField

-- lookupOccRnRecField looks up an occurrence of a RdrName and displays
-- no suggestions if it is not in scope
lookupOccRnNone :: RdrName -> RnM Name
lookupOccRnNone = lookupOccRn' WL_None

-- Only used in one place, to rename pattern synonym binders.
-- See Note [Renaming pattern synonym variables] in GHC.Rename.Bind
lookupLocalOccRn :: RdrName -> RnM Name
lookupLocalOccRn rdr_name
  = do { mb_name <- lookupLocalOccRn_maybe rdr_name
       ; case mb_name of
           Just name -> return name
           Nothing   -> unboundName (LF WL_Anything WL_LocalOnly) rdr_name }

-- lookupTypeOccRn looks up an optionally promoted RdrName.
-- Used for looking up type variables.
lookupTypeOccRn :: RdrName -> RnM Name
-- see Note [Demotion]
lookupTypeOccRn rdr_name
  | isVarOcc (rdrNameOcc rdr_name)  -- See Note [Promoted variables in types]
  = badVarInType rdr_name
  | otherwise
  = do { mb_name <- lookupOccRn_maybe rdr_name
       ; case mb_name of
             Just name -> return name
             Nothing   ->
               if occName rdr_name == occName eqTyCon_RDR -- See Note [eqTyCon (~) compatibility fallback]
               then eqTyConName <$ addDiagnostic TcRnTypeEqualityOutOfScope
               else lookup_demoted rdr_name }

{- Note [eqTyCon (~) compatibility fallback]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Before GHC Proposal #371, the (~) type operator used in type equality
constraints (a~b) was considered built-in syntax.

This had two implications:

1. Users could use it without importing it from Data.Type.Equality or Prelude.
2. TypeOperators were not required to use it (it was guarded behind TypeFamilies/GADTs instead)

To ease migration and minimize breakage, we continue to support those usages
but emit appropriate warnings.
-}

lookup_demoted :: RdrName -> RnM Name
lookup_demoted rdr_name
  | Just demoted_rdr <- demoteRdrName rdr_name
    -- Maybe it's the name of a *data* constructor
  = do { data_kinds <- xoptM LangExt.DataKinds
       ; star_is_type <- xoptM LangExt.StarIsType
       ; let is_star_type = if star_is_type then StarIsType else StarIsNotType
             star_is_type_hints = noStarIsTypeHints is_star_type rdr_name
       ; if data_kinds
            then do { mb_demoted_name <- lookupOccRn_maybe demoted_rdr
                    ; case mb_demoted_name of
                        Nothing -> unboundNameX looking_for rdr_name star_is_type_hints
                        Just demoted_name -> return demoted_name }
            else do { -- We need to check if a data constructor of this name is
                      -- in scope to give good error messages. However, we do
                      -- not want to give an additional error if the data
                      -- constructor happens to be out of scope! See #13947.
                      mb_demoted_name <- discardErrs $
                                         lookupOccRn_maybe demoted_rdr
                    ; let suggestion | isJust mb_demoted_name
                                     , let additional = text "to refer to the data constructor of that name?"
                                     = [SuggestExtension $ SuggestSingleExtension additional LangExt.DataKinds]
                                     | otherwise
                                     = star_is_type_hints
                    ; unboundNameX looking_for rdr_name suggestion } }

  | otherwise
  = reportUnboundName' (lf_which looking_for) rdr_name

  where
    looking_for = LF WL_Constructor WL_Anywhere

-- If the given RdrName can be promoted to the type level and its promoted variant is in scope,
-- lookup_promoted returns the corresponding type-level Name.
-- Otherwise, the function returns Nothing.
-- See Note [Promotion] below.
lookup_promoted :: RdrName -> RnM (Maybe Name)
lookup_promoted rdr_name
  | Just promoted_rdr <- promoteRdrName rdr_name
  = lookupOccRn_maybe promoted_rdr
  | otherwise
  = return Nothing

badVarInType :: RdrName -> RnM Name
badVarInType rdr_name
  = do { addErr (TcRnUnpromotableThing name TermVariablePE)
       ; return name }
      where
        name = mkUnboundNameRdr rdr_name

{- Note [Promoted variables in types]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider this (#12686):
   x = True
   data Bad = Bad 'x

The parser treats the quote in 'x as saying "use the term
namespace", so we'll get (Bad x{v}), with 'x' in the
VarName namespace.  If we don't test for this, the renamer
will happily rename it to the x bound at top level, and then
the typecheck falls over because it doesn't have 'x' in scope
when kind-checking.

Note [Demotion]
~~~~~~~~~~~~~~~
When the user writes:
  data Nat = Zero | Succ Nat
  foo :: f Zero -> Int

'Zero' in the type signature of 'foo' is parsed as:
  HsTyVar ("Zero", TcClsName)

When the renamer hits this occurrence of 'Zero' it's going to realise
that it's not in scope. But because it is renaming a type, it knows
that 'Zero' might be a promoted data constructor, so it will demote
its namespace to DataName and do a second lookup.

The final result (after the renamer) will be:
  HsTyVar ("Zero", DataName)

Note [Promotion]
~~~~~~~~~~~~~~~
When the user mentions a type constructor or a type variable in a
term-level context, then we report that a value identifier was expected
instead of a type-level one. That makes error messages more precise.
Previously, such errors contained only the info that a given value was out of scope (#18740).
We promote the namespace of RdrName and look up after that
(see the functions promotedRdrName and lookup_promoted).

In particular, we have the following error message
  • Illegal term-level use of the type constructor ‘Int’
      imported from ‘Prelude’ (and originally defined in ‘GHC.Types’)
  • In the first argument of ‘id’, namely ‘Int’
    In the expression: id Int
    In an equation for ‘x’: x = id Int

when the user writes the following declaration

  x = id Int
-}

lookupOccRnX_maybe :: (RdrName -> RnM (Maybe r)) -> (Name -> r) -> RdrName
                   -> RnM (Maybe r)
lookupOccRnX_maybe globalLookup wrapper rdr_name
  = runMaybeT . msum . map MaybeT $
      [ fmap wrapper <$> lookupLocalOccRn_maybe rdr_name
      , globalLookup rdr_name ]

-- Used outside this module only by TH name reification (lookupName, lookupThName_maybe)
lookupOccRn_maybe :: RdrName -> RnM (Maybe Name)
lookupOccRn_maybe = lookupOccRnX_maybe lookupGlobalOccRn_maybe id

-- | Look up a 'RdrName' used as a variable in an expression.
--
-- This may be a local variable, global variable, or one or more record selector
-- functions.  It will not return record fields created with the
-- @NoFieldSelectors@ extension (see Note [NoFieldSelectors]).
--
-- If the name is not in scope at the term level, but its promoted equivalent is
-- in scope at the type level, the lookup will succeed (so that the type-checker
-- can report a more informative error later).  See Note [Promotion].
--
lookupExprOccRn :: RdrName -> RnM (Maybe GreName)
lookupExprOccRn rdr_name
  = do { mb_name <- lookupOccRnX_maybe global_lookup NormalGreName rdr_name
       ; case mb_name of
           Nothing   -> fmap @Maybe NormalGreName <$> lookup_promoted rdr_name
                        -- See Note [Promotion].
                        -- We try looking up the name as a
                        -- type constructor or type variable, if
                        -- we failed to look up the name at the term level.
           p         -> return p }

  where
    global_lookup :: RdrName -> RnM (Maybe GreName)
    global_lookup  rdr_name =
      do { mb_name <- lookupGlobalOccRn_overloaded NoDuplicateRecordFields WantNormal rdr_name
         ; case mb_name of
             Just (UnambiguousGre name) -> return (Just name)
             Just _ -> panic "GHC.Rename.Env.global_lookup: The impossible happened!"
             Nothing -> return Nothing
         }

lookupGlobalOccRn_maybe :: RdrName -> RnM (Maybe Name)
-- Looks up a RdrName occurrence in the top-level
-- environment, including using lookupQualifiedNameGHCi
-- for the GHCi case, but first tries to find an Exact or Orig name.
-- No filter function; does not report an error on failure
-- See Note [Errors in lookup functions]
-- Uses addUsedRdrName to record use and deprecations
--
-- Used directly only by getLocalNonValBinders (new_assoc).
lookupGlobalOccRn_maybe rdr_name =
  lookupExactOrOrig_maybe rdr_name id (lookupGlobalOccRn_base WantNormal rdr_name)

lookupGlobalOccRn :: RdrName -> RnM Name
-- lookupGlobalOccRn is like lookupOccRn, except that it looks in the global
-- environment.  Adds an error message if the RdrName is not in scope.
-- You usually want to use "lookupOccRn" which also looks in the local
-- environment.
--
-- Used by exports_from_avail
lookupGlobalOccRn = lookupGlobalOccRn' WantNormal

lookupGlobalOccRn' :: FieldsOrSelectors -> RdrName -> RnM Name
lookupGlobalOccRn' fos rdr_name =
  lookupExactOrOrig rdr_name id $ do
    mn <- lookupGlobalOccRn_base fos rdr_name
    case mn of
      Just n -> return n
      Nothing -> do { traceRn "lookupGlobalOccRn" (ppr rdr_name)
                    ; unboundName (LF which_suggest WL_Global) rdr_name }
        where which_suggest = case fos of
                WantNormal -> WL_Anything
                WantBoth   -> WL_RecField
                WantField  -> WL_RecField

-- Looks up a RdrName occurrence in the GlobalRdrEnv and with
-- lookupQualifiedNameGHCi. Does not try to find an Exact or Orig name first.
-- lookupQualifiedNameGHCi here is used when we're in GHCi and a name like
-- 'Data.Map.elems' is typed, even if you didn't import Data.Map
lookupGlobalOccRn_base :: FieldsOrSelectors -> RdrName -> RnM (Maybe Name)
lookupGlobalOccRn_base fos rdr_name =
  runMaybeT . msum . map MaybeT $
    [ fmap greMangledName <$> lookupGreRn_maybe fos rdr_name
    , fmap greNameMangledName <$> lookupOneQualifiedNameGHCi fos rdr_name ]
                      -- This test is not expensive,
                      -- and only happens for failed lookups

lookupInfoOccRn :: RdrName -> RnM [Name]
-- lookupInfoOccRn is intended for use in GHCi's ":info" command
-- It finds all the GREs that RdrName could mean, not complaining
-- about ambiguity, but rather returning them all
-- C.f. #9881
-- lookupInfoOccRn is also used in situations where we check for
-- at least one definition of the RdrName, not complaining about
-- multiple definitions. (See #17832)
lookupInfoOccRn rdr_name =
  lookupExactOrOrig rdr_name (:[]) $
    do { rdr_env <- getGlobalRdrEnv
       ; let ns = map greMangledName (lookupGRE_RdrName' rdr_name rdr_env)
       ; qual_ns <- map greNameMangledName <$> lookupQualifiedNameGHCi WantBoth rdr_name
       ; return (ns ++ (qual_ns `minusList` ns)) }

-- | Like 'lookupOccRn_maybe', but with a more informative result if
-- the 'RdrName' happens to be a record selector:
--
--   * Nothing                 -> name not in scope (no error reported)
--   * Just (UnambiguousGre x) -> name uniquely refers to x,
--                                or there is a name clash (reported)
--   * Just AmbiguousFields    -> name refers to two or more record fields
--                                (no error reported)
--
-- See Note [ Unbound vs Ambiguous Names ].
lookupGlobalOccRn_overloaded :: DuplicateRecordFields -> FieldsOrSelectors -> RdrName
                             -> RnM (Maybe AmbiguousResult)
lookupGlobalOccRn_overloaded dup_fields_ok fos rdr_name =
  lookupExactOrOrig_maybe rdr_name (fmap (UnambiguousGre . NormalGreName)) $
    do { res <- lookupGreRn_helper fos rdr_name
       ; case res of
           GreNotFound -> fmap UnambiguousGre <$> lookupOneQualifiedNameGHCi fos rdr_name
           OneNameMatch gre -> return $ Just (UnambiguousGre (gre_name gre))
           MultipleNames gres
             | all isRecFldGRE gres
             , dup_fields_ok == DuplicateRecordFields -> return $ Just AmbiguousFields
             | otherwise -> do
                  addNameClashErrRn rdr_name gres
                  return (Just (UnambiguousGre (gre_name (NE.head gres)))) }


-- | Result of looking up an occurrence that might be an ambiguous field.
data AmbiguousResult
    = UnambiguousGre GreName
    -- ^ Occurrence picked out a single name, which may or may not belong to a
    -- field (or might be unbound, if an error has been reported already, per
    -- Note [ Unbound vs Ambiguous Names ]).
    | AmbiguousFields
    -- ^ Occurrence picked out two or more fields, and no non-fields.  For now
    -- this is allowed by DuplicateRecordFields in certain circumstances, as the
    -- type-checker may be able to disambiguate later.


{-
Note [NoFieldSelectors]
~~~~~~~~~~~~~~~~~~~~~~~
The NoFieldSelectors extension allows record fields to be defined without
bringing the corresponding selector functions into scope.  However, such fields
may still be used in contexts such as record construction, pattern matching or
update. This requires us to distinguish contexts in which selectors are required
from those in which any field may be used.  For example:

  {-# LANGUAGE NoFieldSelectors #-}
  module M (T(foo), foo) where  -- T(foo) refers to the field,
                                -- unadorned foo to the value binding
    data T = MkT { foo :: Int }
    foo = ()

    bar = foo -- refers to the value binding, field ignored

  module N where
    import M (T(..))
    baz = MkT { foo = 3 } -- refers to the field
    oops = foo -- an error: the field is in scope but the value binding is not

Each 'FieldLabel' indicates (in the 'flHasFieldSelector' field) whether the
FieldSelectors extension was enabled in the defining module.  This allows them
to be filtered out by 'filterFieldGREs'.

Even when NoFieldSelectors is in use, we still generate selector functions
internally. For example, the expression
   getField @"foo" t
or (with dot-notation)
   t.foo
extracts the `foo` field of t::T, and hence needs the selector function
(see Note [HasField instances] in GHC.Tc.Instance.Class).  In order to avoid
name clashes with normal bindings reusing the names, selector names for such
fields are mangled just as for DuplicateRecordFields (see Note [FieldLabel] in
GHC.Types.FieldLabel).


In many of the name lookup functions in this module we pass a FieldsOrSelectors
value, indicating what we are looking for:

 * WantNormal: fields are in scope only if they have an accompanying selector
   function, e.g. we are looking up a variable in an expression
   (lookupExprOccRn).

 * WantBoth: any name or field will do, regardless of whether the selector
   function is available, e.g. record updates (lookupRecFieldOcc_update) with
   NoDisambiguateRecordFields.

 * WantField: any field will do, regardless of whether the selector function is
   available, but ignoring any non-field names, e.g. record updates
   (lookupRecFieldOcc_update) with DisambiguateRecordFields.

-----------------------------------------------------------------------------------
  Context                                  FieldsOrSelectors
-----------------------------------------------------------------------------------
  Record construction/pattern match        WantBoth if NoDisambiguateRecordFields
  e.g. MkT { foo = 3 }                     (DisambiguateRecordFields is separate)

  Record update                            WantBoth if NoDisambiguateRecordFields
  e.g. e { foo = 3 }                       WantField if DisambiguateRecordFields

  :info in GHCi                            WantBoth

  Variable occurrence in expression        WantNormal
  Type variable, data constructor
  Pretty much everything else
-----------------------------------------------------------------------------------
-}

-- | When looking up GREs, we may or may not want to include fields that were
-- defined in modules with @NoFieldSelectors@ enabled.  See Note
-- [NoFieldSelectors].
data FieldsOrSelectors
    = WantNormal -- ^ Include normal names, and fields with selectors, but
                 -- ignore fields without selectors.
    | WantBoth   -- ^ Include normal names and all fields (regardless of whether
                 -- they have selectors).
    | WantField  -- ^ Include only fields, with or without selectors, ignoring
                 -- any non-fields in scope.
  deriving Eq

filterFieldGREs :: FieldsOrSelectors -> [GlobalRdrElt] -> [GlobalRdrElt]
filterFieldGREs fos = filter (allowGreName fos . gre_name)

allowGreName :: FieldsOrSelectors -> GreName -> Bool
allowGreName WantBoth   _                 = True
allowGreName WantNormal (FieldGreName fl) = flHasFieldSelector fl == FieldSelectors
allowGreName WantNormal (NormalGreName _) = True
allowGreName WantField  (FieldGreName  _) = True
allowGreName WantField  (NormalGreName _) = False


--------------------------------------------------
--      Lookup in the Global RdrEnv of the module
--------------------------------------------------

data GreLookupResult = GreNotFound
                     | OneNameMatch GlobalRdrElt
                     | MultipleNames (NE.NonEmpty GlobalRdrElt)

lookupGreRn_maybe :: FieldsOrSelectors -> RdrName -> RnM (Maybe GlobalRdrElt)
-- Look up the RdrName in the GlobalRdrEnv
--   Exactly one binding: records it as "used", return (Just gre)
--   No bindings:         return Nothing
--   Many bindings:       report "ambiguous", return an arbitrary (Just gre)
-- Uses addUsedRdrName to record use and deprecations
lookupGreRn_maybe fos rdr_name
  = do
      res <- lookupGreRn_helper fos rdr_name
      case res of
        OneNameMatch gre ->  return $ Just gre
        MultipleNames gres -> do
          traceRn "lookupGreRn_maybe:NameClash" (ppr gres)
          addNameClashErrRn rdr_name gres
          return $ Just (NE.head gres)
        GreNotFound -> return Nothing

{-

Note [ Unbound vs Ambiguous Names ]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
lookupGreRn_maybe deals with failures in two different ways. If a name
is unbound then we return a `Nothing` but if the name is ambiguous
then we raise an error and return a dummy name.

The reason for this is that when we call `lookupGreRn_maybe` we are
speculatively looking for whatever we are looking up. If we don't find it,
then we might have been looking for the wrong thing and can keep trying.
On the other hand, if we find a clash then there is no way to recover as
we found the thing we were looking for but can no longer resolve which
the correct one is.

One example of this is in `lookupTypeOccRn` which first looks in the type
constructor namespace before looking in the data constructor namespace to
deal with `DataKinds`.

There is however, as always, one exception to this scheme. If we find
an ambiguous occurrence of a record selector and DuplicateRecordFields
is enabled then we defer the selection until the typechecker.

-}




-- Internal Function
lookupGreRn_helper :: FieldsOrSelectors -> RdrName -> RnM GreLookupResult
lookupGreRn_helper fos rdr_name
  = do  { env <- getGlobalRdrEnv
        ; case filterFieldGREs fos (lookupGRE_RdrName' rdr_name env) of
            []    -> return GreNotFound
            [gre] -> do { addUsedGRE True gre
                        ; return (OneNameMatch gre) }
            -- Don't record usage for ambiguous names
            -- until we know which is meant
            (gre:gres) -> return (MultipleNames (gre NE.:| gres)) }

lookupGreAvailRn :: RdrName -> RnM (Name, AvailInfo)
-- Used in export lists
-- If not found or ambiguous, add error message, and fake with UnboundName
-- Uses addUsedRdrName to record use and deprecations
lookupGreAvailRn rdr_name
  = do
      mb_gre <- lookupGreRn_helper WantNormal rdr_name
      case mb_gre of
        GreNotFound ->
          do
            traceRn "lookupGreAvailRn" (ppr rdr_name)
            name <- unboundName (LF WL_Anything WL_Global) rdr_name
            return (name, avail name)
        MultipleNames gres ->
          do
            addNameClashErrRn rdr_name gres
            let unbound_name = mkUnboundNameRdr rdr_name
            return (unbound_name, avail unbound_name)
                        -- Returning an unbound name here prevents an error
                        -- cascade
        OneNameMatch gre ->
          return (greMangledName gre, availFromGRE gre)


{-
*********************************************************
*                                                      *
                Deprecations
*                                                      *
*********************************************************

Note [Handling of deprecations]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
* We report deprecations at each *occurrence* of the deprecated thing
  (see #5867)

* We do not report deprecations for locally-defined names. For a
  start, we may be exporting a deprecated thing. Also we may use a
  deprecated thing in the defn of another deprecated things.  We may
  even use a deprecated thing in the defn of a non-deprecated thing,
  when changing a module's interface.

* addUsedGREs: we do not report deprecations for sub-binders:
     - the ".." completion for records
     - the ".." in an export item 'T(..)'
     - the things exported by a module export 'module M'
-}

addUsedDataCons :: GlobalRdrEnv -> TyCon -> RnM ()
-- Remember use of in-scope data constructors (#7969)
addUsedDataCons rdr_env tycon
  = addUsedGREs [ gre
                | dc <- tyConDataCons tycon
                , Just gre <- [lookupGRE_Name rdr_env (dataConName dc)] ]

addUsedGRE :: Bool -> GlobalRdrElt -> RnM ()
-- Called for both local and imported things
-- Add usage *and* warn if deprecated
addUsedGRE warn_if_deprec gre
  = do { when warn_if_deprec (warnIfDeprecated gre)
       ; unless (isLocalGRE gre) $
         do { env <- getGblEnv
            ; traceRn "addUsedGRE" (ppr gre)
            ; updMutVar (tcg_used_gres env) (gre :) } }

addUsedGREs :: [GlobalRdrElt] -> RnM ()
-- Record uses of any *imported* GREs
-- Used for recording used sub-bndrs
-- NB: no call to warnIfDeprecated; see Note [Handling of deprecations]
addUsedGREs gres
  | null imp_gres = return ()
  | otherwise     = do { env <- getGblEnv
                       ; traceRn "addUsedGREs" (ppr imp_gres)
                       ; updMutVar (tcg_used_gres env) (imp_gres ++) }
  where
    imp_gres = filterOut isLocalGRE gres

warnIfDeprecated :: GlobalRdrElt -> RnM ()
warnIfDeprecated gre@(GRE { gre_imp = iss })
  | Just imp_spec <- headMaybe iss
  = do { dflags <- getDynFlags
       ; this_mod <- getModule
       ; when (wopt Opt_WarnWarningsDeprecations dflags &&
               not (nameIsLocalOrFrom this_mod name)) $
                   -- See Note [Handling of deprecations]
         do { iface <- loadInterfaceForName doc name
            ; case lookupImpDeprec iface gre of
                Just deprText -> addDiagnostic $
                  TcRnPragmaWarning {
                    pragma_warning_occ = occ,
                    pragma_warning_msg = deprText,
                    pragma_warning_import_mod = importSpecModule imp_spec,
                    pragma_warning_defined_mod = definedMod
                  }
                Nothing  -> return () } }
  | otherwise
  = return ()
  where
    occ = greOccName gre
    name = greMangledName gre
    definedMod = moduleName $ assertPpr (isExternalName name) (ppr name) (nameModule name)
    doc = text "The name" <+> quotes (ppr occ) <+> text "is mentioned explicitly"

lookupImpDeprec :: ModIface -> GlobalRdrElt -> Maybe (WarningTxt GhcRn)
lookupImpDeprec iface gre
  = mi_warn_fn (mi_final_exts iface) (greOccName gre) `mplus`  -- Bleat if the thing,
    case gre_par gre of                      -- or its parent, is warn'd
       ParentIs  p              -> mi_warn_fn (mi_final_exts iface) (nameOccName p)
       NoParent                 -> Nothing

{-
Note [Used names with interface not loaded]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
It's (just) possible to find a used
Name whose interface hasn't been loaded:

a) It might be a WiredInName; in that case we may not load
   its interface (although we could).

b) It might be GHC.Real.fromRational, or GHC.Num.fromInteger
   These are seen as "used" by the renamer (if -XRebindableSyntax)
   is on), but the typechecker may discard their uses
   if in fact the in-scope fromRational is GHC.Read.fromRational,
   (see tcPat.tcOverloadedLit), and the typechecker sees that the type
   is fixed, say, to GHC.Base.Float (see Inst.lookupSimpleInst).
   In that obscure case it won't force the interface in.

In both cases we simply don't permit deprecations;
this is, after all, wired-in stuff.


*********************************************************
*                                                      *
                GHCi support
*                                                      *
*********************************************************

A qualified name on the command line can refer to any module at
all: we try to load the interface if we don't already have it, just
as if there was an "import qualified M" declaration for every
module.

For example, writing `Data.List.sort` will load the interface file for
`Data.List` as if the user had written `import qualified Data.List`.

If we fail we just return Nothing, rather than bleating
about "attempting to use module ‘D’ (./D.hs) which is not loaded"
which is what loadSrcInterface does.

It is enabled by default and disabled by the flag
`-fno-implicit-import-qualified`.

Note [Safe Haskell and GHCi]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We DON'T do this Safe Haskell as we need to check imports. We can
and should instead check the qualified import but at the moment
this requires some refactoring so leave as a TODO

Note [DuplicateRecordFields and -fimplicit-import-qualified]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When DuplicateRecordFields is used, a single module can export the same OccName
multiple times, for example:

  module M where
    data S = MkS { foo :: Int }
    data T = MkT { foo :: Int }

Now if we refer to M.foo via -fimplicit-import-qualified, we need to report an
ambiguity error.

-}


-- | Like 'lookupQualifiedNameGHCi' but returning at most one name, reporting an
-- ambiguity error if there are more than one.
lookupOneQualifiedNameGHCi :: FieldsOrSelectors -> RdrName -> RnM (Maybe GreName)
lookupOneQualifiedNameGHCi fos rdr_name = do
    gnames <- lookupQualifiedNameGHCi fos rdr_name
    case gnames of
      []              -> return Nothing
      [gname]         -> return (Just gname)
      (gname:gnames') -> do addNameClashErrRn rdr_name (toGRE gname NE.:| map toGRE gnames')
                            return (Just (NormalGreName (mkUnboundNameRdr rdr_name)))
  where
    -- Fake a GRE so we can report a sensible name clash error if
    -- -fimplicit-import-qualified is used with a module that exports the same
    -- field name multiple times (see
    -- Note [DuplicateRecordFields and -fimplicit-import-qualified]).
    toGRE gname = GRE { gre_name = gname, gre_par = NoParent, gre_lcl = False, gre_imp = unitBag is }
    is = ImpSpec { is_decl = ImpDeclSpec { is_mod = mod, is_as = mod, is_qual = True, is_dloc = noSrcSpan }
                 , is_item = ImpAll }
    -- If -fimplicit-import-qualified succeeded, the name must be qualified.
    (mod, _) = fromMaybe (pprPanic "lookupOneQualifiedNameGHCi" (ppr rdr_name)) (isQual_maybe rdr_name)


-- | Look up *all* the names to which the 'RdrName' may refer in GHCi (using
-- @-fimplicit-import-qualified@).  This will normally be zero or one, but may
-- be more in the presence of @DuplicateRecordFields@.
lookupQualifiedNameGHCi :: FieldsOrSelectors -> RdrName -> RnM [GreName]
lookupQualifiedNameGHCi fos rdr_name
  = -- We want to behave as we would for a source file import here,
    -- and respect hiddenness of modules/packages, hence loadSrcInterface.
    do { dflags  <- getDynFlags
       ; is_ghci <- getIsGHCi
       ; go_for_it dflags is_ghci }

  where
    go_for_it dflags is_ghci
      | Just (mod,occ) <- isQual_maybe rdr_name
      , is_ghci
      , gopt Opt_ImplicitImportQualified dflags   -- Enables this GHCi behaviour
      , not (safeDirectImpsReq dflags)            -- See Note [Safe Haskell and GHCi]
      = do { res <- loadSrcInterface_maybe doc mod NotBoot NoPkgQual
           ; case res of
                Succeeded iface
                  -> return [ gname
                            | avail <- mi_exports iface
                            , gname <- availGreNames avail
                            , occName gname == occ
                            -- Include a field if it has a selector or we are looking for all fields;
                            -- see Note [NoFieldSelectors].
                            , allowGreName fos gname
                            ]

                _ -> -- Either we couldn't load the interface, or
                     -- we could but we didn't find the name in it
                     do { traceRn "lookupQualifiedNameGHCi" (ppr rdr_name)
                        ; return [] } }

      | otherwise
      = do { traceRn "lookupQualifiedNameGHCi: off" (ppr rdr_name)
           ; return [] }

    doc = text "Need to find" <+> ppr rdr_name

{-
Note [Looking up signature names]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
lookupSigOccRn is used for type signatures and pragmas
Is this valid?
  module A
        import M( f )
        f :: Int -> Int
        f x = x
It's clear that the 'f' in the signature must refer to A.f
The Haskell98 report does not stipulate this, but it will!
So we must treat the 'f' in the signature in the same way
as the binding occurrence of 'f', using lookupBndrRn

However, consider this case:
        import M( f )
        f :: Int -> Int
        g x = x
We don't want to say 'f' is out of scope; instead, we want to
return the imported 'f', so that later on the renamer will
correctly report "misplaced type sig".

Note [Signatures for top level things]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
data HsSigCtxt = ... | TopSigCtxt NameSet | ....

* The NameSet says what is bound in this group of bindings.
  We can't use isLocalGRE from the GlobalRdrEnv, because of this:
       f x = x
       $( ...some TH splice... )
       f :: Int -> Int
  When we encounter the signature for 'f', the binding for 'f'
  will be in the GlobalRdrEnv, and will be a LocalDef. Yet the
  signature is mis-placed

* For type signatures the NameSet should be the names bound by the
  value bindings; for fixity declarations, the NameSet should also
  include class sigs and record selectors

      infix 3 `f`          -- Yes, ok
      f :: C a => a -> a   -- No, not ok
      class C a where
        f :: a -> a
-}

data HsSigCtxt
  = TopSigCtxt NameSet       -- At top level, binding these names
                             -- See Note [Signatures for top level things]
  | LocalBindCtxt NameSet    -- In a local binding, binding these names
  | ClsDeclCtxt   Name       -- Class decl for this class
  | InstDeclCtxt  NameSet    -- Instance decl whose user-written method
                             -- bindings are for these methods
  | HsBootCtxt NameSet       -- Top level of a hs-boot file, binding these names
  | RoleAnnotCtxt NameSet    -- A role annotation, with the names of all types
                             -- in the group

instance Outputable HsSigCtxt where
    ppr (TopSigCtxt ns) = text "TopSigCtxt" <+> ppr ns
    ppr (LocalBindCtxt ns) = text "LocalBindCtxt" <+> ppr ns
    ppr (ClsDeclCtxt n) = text "ClsDeclCtxt" <+> ppr n
    ppr (InstDeclCtxt ns) = text "InstDeclCtxt" <+> ppr ns
    ppr (HsBootCtxt ns) = text "HsBootCtxt" <+> ppr ns
    ppr (RoleAnnotCtxt ns) = text "RoleAnnotCtxt" <+> ppr ns

lookupSigOccRn :: HsSigCtxt
               -> Sig GhcPs
               -> LocatedA RdrName -> RnM (LocatedA Name)
lookupSigOccRn ctxt sig = lookupSigCtxtOccRn ctxt (hsSigDoc sig)

lookupSigOccRnN :: HsSigCtxt
               -> Sig GhcPs
               -> LocatedN RdrName -> RnM (LocatedN Name)
lookupSigOccRnN ctxt sig = lookupSigCtxtOccRnN ctxt (hsSigDoc sig)


-- | Lookup a name in relation to the names in a 'HsSigCtxt'
lookupSigCtxtOccRnN :: HsSigCtxt
                    -> SDoc         -- ^ description of thing we're looking up,
                                   -- like "type family"
                    -> LocatedN RdrName -> RnM (LocatedN Name)
lookupSigCtxtOccRnN ctxt what
  = wrapLocMA $ \ rdr_name ->
    do { mb_name <- lookupBindGroupOcc ctxt what rdr_name
       ; case mb_name of
           Left err   -> do { addErr (mkTcRnNotInScope rdr_name err)
                            ; return (mkUnboundNameRdr rdr_name) }
           Right name -> return name }

-- | Lookup a name in relation to the names in a 'HsSigCtxt'
lookupSigCtxtOccRn :: HsSigCtxt
                   -> SDoc         -- ^ description of thing we're looking up,
                                   -- like "type family"
                   -> LocatedA RdrName -> RnM (LocatedA Name)
lookupSigCtxtOccRn ctxt what
  = wrapLocMA $ \ rdr_name ->
    do { mb_name <- lookupBindGroupOcc ctxt what rdr_name
       ; case mb_name of
           Left err   -> do { addErr (mkTcRnNotInScope rdr_name err)
                            ; return (mkUnboundNameRdr rdr_name) }
           Right name -> return name }

lookupBindGroupOcc :: HsSigCtxt
                   -> SDoc
                   -> RdrName -> RnM (Either NotInScopeError Name)
-- Looks up the RdrName, expecting it to resolve to one of the
-- bound names passed in.  If not, return an appropriate error message
--
-- See Note [Looking up signature names]
lookupBindGroupOcc ctxt what rdr_name
  | Just n <- isExact_maybe rdr_name
  = lookupExactOcc_either n   -- allow for the possibility of missing Exacts;
                              -- see Note [dataTcOccs and Exact Names]
      -- Maybe we should check the side conditions
      -- but it's a pain, and Exact things only show
      -- up when you know what you are doing

  | Just (rdr_mod, rdr_occ) <- isOrig_maybe rdr_name
  = do { n' <- lookupOrig rdr_mod rdr_occ
       ; return (Right n') }

  | otherwise
  = case ctxt of
      HsBootCtxt ns    -> lookup_top (`elemNameSet` ns)
      TopSigCtxt ns    -> lookup_top (`elemNameSet` ns)
      RoleAnnotCtxt ns -> lookup_top (`elemNameSet` ns)
      LocalBindCtxt ns -> lookup_group ns
      ClsDeclCtxt  cls -> lookup_cls_op cls
      InstDeclCtxt ns  -> if uniqSetAny isUnboundName ns -- #16610
                          then return (Right $ mkUnboundNameRdr rdr_name)
                          else lookup_top (`elemNameSet` ns)
  where
    lookup_cls_op cls
      = lookupSubBndrOcc True cls doc rdr_name
      where
        doc = text "method of class" <+> quotes (ppr cls)

    lookup_top keep_me
      = do { env <- getGlobalRdrEnv
           ; dflags <- getDynFlags
           ; let all_gres = lookupGlobalRdrEnv env (rdrNameOcc rdr_name)
                 names_in_scope = -- If rdr_name lacks a binding, only
                                  -- recommend alternatives from related
                                  -- namespaces. See #17593.
                                  filter (\n -> nameSpacesRelated dflags WL_Anything
                                                  (rdrNameSpace rdr_name)
                                                  (nameNameSpace n))
                                $ map greMangledName
                                $ filter isLocalGRE
                                $ globalRdrEnvElts env
                 candidates_msg = candidates names_in_scope
           ; case filter (keep_me . greMangledName) all_gres of
               [] | null all_gres -> bale_out_with candidates_msg
                  | otherwise     -> bale_out_with local_msg
               (gre:_)            -> return (Right (greMangledName gre)) }

    lookup_group bound_names  -- Look in the local envt (not top level)
      = do { mname <- lookupLocalOccRn_maybe rdr_name
           ; env <- getLocalRdrEnv
           ; let candidates_msg = candidates $ localRdrEnvElts env
           ; case mname of
               Just n
                 | n `elemNameSet` bound_names -> return (Right n)
                 | otherwise                   -> bale_out_with local_msg
               Nothing                         -> bale_out_with candidates_msg }

    bale_out_with hints = return (Left $ MissingBinding what hints)

    local_msg = [SuggestMoveToDeclarationSite what rdr_name]

    -- Identify all similar names and produce a message listing them
    candidates :: [Name] -> [GhcHint]
    candidates names_in_scope
      | (nm : nms) <- map SimilarName similar_names
      = [SuggestSimilarNames rdr_name (nm NE.:| nms)]
      | otherwise
      = []
      where
        similar_names
          = fuzzyLookup (unpackFS $ occNameFS $ rdrNameOcc rdr_name)
                        $ map (\x -> ((unpackFS $ occNameFS $ nameOccName x), x))
                              names_in_scope


---------------
lookupLocalTcNames :: HsSigCtxt -> SDoc -> RdrName -> RnM [(RdrName, Name)]
-- GHC extension: look up both the tycon and data con or variable.
-- Used for top-level fixity signatures and deprecations.
-- Complain if neither is in scope.
-- See Note [Fixity signature lookup]
lookupLocalTcNames ctxt what rdr_name
  = do { mb_gres <- mapM lookup (dataTcOccs rdr_name)
       ; let (errs, names) = partitionEithers mb_gres
       ; when (null names) $
          addErr (head errs) -- Bleat about one only
       ; return names }
  where
    lookup rdr = do { this_mod <- getModule
                    ; nameEither <- lookupBindGroupOcc ctxt what rdr
                    ; return (guard_builtin_syntax this_mod rdr nameEither) }

    -- Guard against the built-in syntax (ex: `infixl 6 :`), see #15233
    guard_builtin_syntax this_mod rdr (Right name)
      | Just _ <- isBuiltInOcc_maybe (occName rdr)
      , this_mod /= nameModule name
      = Left $ TcRnIllegalBuiltinSyntax what rdr
      | otherwise
      = Right (rdr, name)
    guard_builtin_syntax _ _ (Left err)
      = Left $ mkTcRnNotInScope rdr_name err

dataTcOccs :: RdrName -> [RdrName]
-- Return both the given name and the same name promoted to the TcClsName
-- namespace.  This is useful when we aren't sure which we are looking at.
-- See also Note [dataTcOccs and Exact Names]
dataTcOccs rdr_name
  | isDataOcc occ || isVarOcc occ
  = [rdr_name, rdr_name_tc]
  | otherwise
  = [rdr_name]
  where
    occ = rdrNameOcc rdr_name
    rdr_name_tc = setRdrNameSpace rdr_name tcName

{-
Note [dataTcOccs and Exact Names]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Exact RdrNames can occur in code generated by Template Haskell, and generally
those references are, well, exact. However, the TH `Name` type isn't expressive
enough to always track the correct namespace information, so we sometimes get
the right Unique but wrong namespace. Thus, we still have to do the double-lookup
for Exact RdrNames.

There is also an awkward situation for built-in syntax. Example in GHCi
   :info []
This parses as the Exact RdrName for nilDataCon, but we also want
the list type constructor.

Note that setRdrNameSpace on an Exact name requires the Name to be External,
which it always is for built in syntax.
-}



{-
************************************************************************
*                                                                      *
                        Rebindable names
        Dealing with rebindable syntax is driven by the
        Opt_RebindableSyntax dynamic flag.

        In "deriving" code we don't want to use rebindable syntax
        so we switch off the flag locally

*                                                                      *
************************************************************************

Haskell 98 says that when you say "3" you get the "fromInteger" from the
Standard Prelude, regardless of what is in scope.   However, to experiment
with having a language that is less coupled to the standard prelude, we're
trying a non-standard extension that instead gives you whatever "Prelude.fromInteger"
happens to be in scope.  Then you can
        import Prelude ()
        import MyPrelude as Prelude
to get the desired effect.

At the moment this just happens for
  * fromInteger, fromRational on literals (in expressions and patterns)
  * negate (in expressions)
  * minus  (arising from n+k patterns)
  * "do" notation

We store the relevant Name in the HsSyn tree, in
  * HsIntegral/HsFractional/HsIsString
  * NegApp
  * NPlusKPat
  * HsDo
respectively.  Initially, we just store the "standard" name (GHC.Builtin.Names.fromIntegralName,
fromRationalName etc), but the renamer changes this to the appropriate user
name if Opt_NoImplicitPrelude is on.  That is what lookupSyntax does.

We treat the original (standard) names as free-vars too, because the type checker
checks the type of the user thing against the type of the standard thing.
-}

lookupIfThenElse :: RnM (Maybe Name)
-- Looks up "ifThenElse" if rebindable syntax is on
lookupIfThenElse
  = do { rebindable_on <- xoptM LangExt.RebindableSyntax
       ; if not rebindable_on
         then return Nothing
         else do { ite <- lookupOccRnNone (mkVarUnqual (fsLit "ifThenElse"))
                 ; return (Just ite) } }

lookupSyntaxName :: Name                 -- ^ The standard name
                 -> RnM (Name, FreeVars) -- ^ Possibly a non-standard name
-- Lookup a Name that may be subject to Rebindable Syntax (RS).
--
-- - When RS is off, just return the supplied (standard) Name
--
-- - When RS is on, look up the OccName of the supplied Name; return
--   what we find, or the supplied Name if there is nothing in scope
lookupSyntaxName std_name
  = do { rebind <- xoptM LangExt.RebindableSyntax
       ; if not rebind
         then return (std_name, emptyFVs)
         else do { nm <- lookupOccRnNone (mkRdrUnqual (nameOccName std_name))
                 ; return (nm, unitFV nm) } }

lookupSyntaxExpr :: Name                          -- ^ The standard name
                 -> RnM (HsExpr GhcRn, FreeVars)  -- ^ Possibly a non-standard name
lookupSyntaxExpr std_name
  = do { (name, fvs) <- lookupSyntaxName std_name
       ; return (nl_HsVar name, fvs) }

lookupSyntax :: Name                             -- The standard name
             -> RnM (SyntaxExpr GhcRn, FreeVars) -- Possibly a non-standard
                                                 -- name
lookupSyntax std_name
  = do { (expr, fvs) <- lookupSyntaxExpr std_name
       ; return (mkSyntaxExpr expr, fvs) }

lookupSyntaxNames :: [Name]                         -- Standard names
     -> RnM ([HsExpr GhcRn], FreeVars) -- See comments with HsExpr.ReboundNames
   -- this works with CmdTop, which wants HsExprs, not SyntaxExprs
lookupSyntaxNames std_names
  = do { rebindable_on <- xoptM LangExt.RebindableSyntax
       ; if not rebindable_on then
             return (map (HsVar noExtField . noLocA) std_names, emptyFVs)
        else
          do { usr_names <-
                 mapM (lookupOccRnNone . mkRdrUnqual . nameOccName) std_names
             ; return (map (HsVar noExtField . noLocA) usr_names, mkFVs usr_names) } }


{-
Note [QualifiedDo]
~~~~~~~~~~~~~~~~~~
QualifiedDo is implemented using the same placeholders for operation names in
the AST that were devised for RebindableSyntax. Whenever the renamer checks
which names to use for do syntax, it first checks if the do block is qualified
(e.g. M.do { stmts }), in which case it searches for qualified names. If the
qualified names are not in scope, an error is produced. If the do block is not
qualified, the renamer does the usual search of the names which considers
whether RebindableSyntax is enabled or not. Dealing with QualifiedDo is driven
by the Opt_QualifiedDo dynamic flag.
-}

-- Lookup operations for a qualified do. If the context is not a qualified
-- do, then use lookupSyntaxExpr. See Note [QualifiedDo].
lookupQualifiedDoExpr :: HsStmtContext p -> Name -> RnM (HsExpr GhcRn, FreeVars)
lookupQualifiedDoExpr ctxt std_name
  = first nl_HsVar <$> lookupQualifiedDoName ctxt std_name

-- Like lookupQualifiedDoExpr but for producing SyntaxExpr.
-- See Note [QualifiedDo].
lookupQualifiedDo
  :: HsStmtContext p
  -> Name
  -> RnM (SyntaxExpr GhcRn, FreeVars)
lookupQualifiedDo ctxt std_name
  = first mkSyntaxExpr <$> lookupQualifiedDoExpr ctxt std_name

lookupNameWithQualifier :: Name -> ModuleName -> RnM (Name, FreeVars)
lookupNameWithQualifier std_name modName
  = do { qname <- lookupOccRnNone (mkRdrQual modName (nameOccName std_name))
       ; return (qname, unitFV qname) }

-- See Note [QualifiedDo].
lookupQualifiedDoName
  :: HsStmtContext p
  -> Name
  -> RnM (Name, FreeVars)
lookupQualifiedDoName ctxt std_name
  = case qualifiedDoModuleName_maybe ctxt of
      Nothing -> lookupSyntaxName std_name
      Just modName -> lookupNameWithQualifier std_name modName


-- Error messages

badOrigBinding :: RdrName -> TcRnMessage
badOrigBinding name
  | Just _ <- isBuiltInOcc_maybe occ = TcRnIllegalBindingOfBuiltIn occ
  | otherwise = TcRnNameByTemplateHaskellQuote name
  where
    occ = rdrNameOcc $ filterCTuple name
