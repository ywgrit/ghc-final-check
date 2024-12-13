{-# LANGUAGE ViewPatterns #-}

-- | Code generation for the Static Pointer Table
--
-- (c) 2014 I/O Tweag
--
-- Each module that uses 'static' keyword declares an initialization function of
-- the form hs_spt_init_\<module>() which is emitted into the _stub.c file and
-- annotated with __attribute__((constructor)) so that it gets executed at
-- startup time.
--
-- The function's purpose is to call hs_spt_insert to insert the static
-- pointers of this module in the hashtable of the RTS, and it looks something
-- like this:
--
-- > static void hs_hpc_init_Main(void) __attribute__((constructor));
-- > static void hs_hpc_init_Main(void) {
-- >
-- >   static StgWord64 k0[2] = {16252233372134256ULL,7370534374096082ULL};
-- >   extern StgPtr Main_r2wb_closure;
-- >   hs_spt_insert(k0, &Main_r2wb_closure);
-- >
-- >   static StgWord64 k1[2] = {12545634534567898ULL,5409674567544151ULL};
-- >   extern StgPtr Main_r2wc_closure;
-- >   hs_spt_insert(k1, &Main_r2wc_closure);
-- >
-- > }
--
-- where the constants are fingerprints produced from the static forms.
--
-- The linker must find the definitions matching the @extern StgPtr <name>@
-- declarations. For this to work, the identifiers of static pointers need to be
-- exported. This is done in 'GHC.Core.Opt.SetLevels.newLvlVar'.
--
-- There is also a finalization function for the time when the module is
-- unloaded.
--
-- > static void hs_hpc_fini_Main(void) __attribute__((destructor));
-- > static void hs_hpc_fini_Main(void) {
-- >
-- >   static StgWord64 k0[2] = {16252233372134256ULL,7370534374096082ULL};
-- >   hs_spt_remove(k0);
-- >
-- >   static StgWord64 k1[2] = {12545634534567898ULL,5409674567544151ULL};
-- >   hs_spt_remove(k1);
-- >
-- > }
--

module GHC.Iface.Tidy.StaticPtrTable
  ( sptCreateStaticBinds
  , sptModuleInitCode
  , StaticPtrOpts (..)
  )
where

{- Note [Grand plan for static forms]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Static forms go through the compilation phases as follows.
Here is a running example:

   f x = let k = map toUpper
         in ...(static k)...

* The renamer looks for out-of-scope names in the body of the static
  form, as always. If all names are in scope, the free variables of the
  body are stored in AST at the location of the static form.

* The typechecker verifies that all free variables occurring in the
  static form are floatable to top level (see Note [Meaning of
  IdBindingInfo] in GHC.Tc.Types).  In our example, 'k' is floatable.
  Even though it is bound in a nested let, we are fine.

* The desugarer replaces the static form with an application of the
  function 'makeStatic' (defined in module GHC.StaticPtr.Internal of
  base).  So we get

   f x = let k = map toUpper
         in ...fromStaticPtr (makeStatic location k)...

* The simplifier runs the FloatOut pass which moves the calls to 'makeStatic'
  to the top level. Thus the FloatOut pass is always executed, even when
  optimizations are disabled.  So we get

   k = map toUpper
   static_ptr = makeStatic location k
   f x = ...fromStaticPtr static_ptr...

  The FloatOut pass is careful to produce an /exported/ Id for a floated
  'makeStatic' call, so the binding is not removed or inlined by the
  simplifier.
  E.g. the code for `f` above might look like

    static_ptr = makeStatic location k
    f x = ...(case static_ptr of ...)...

  which might be simplified to

    f x = ...(case makeStatic location k of ...)...

  BUT the top-level binding for static_ptr must remain, so that it can be
  collected to populate the Static Pointer Table.

  Making the binding exported also has a necessary effect during the
  CoreTidy pass.

* The CoreTidy pass replaces all bindings of the form

  b = /\ ... -> makeStatic location value

  with

  b = /\ ... -> StaticPtr key (StaticPtrInfo "pkg key" "module" location) value

  where a distinct key is generated for each binding.

* If we are compiling to object code we insert a C stub (generated by
  sptModuleInitCode) into the final object which runs when the module is loaded,
  inserting the static forms defined by the module into the RTS's static pointer
  table.

* If we are compiling for the byte-code interpreter, we instead explicitly add
  the SPT entries (recorded in CgGuts' cg_spt_entries field) to the interpreter
  process' SPT table using the addSptEntry interpreter message. This happens
  in upsweep after we have compiled the module (see GHC.Driver.Make.upsweep').
-}

import GHC.Prelude
import GHC.Platform

import GHC.Core
import GHC.Core.Utils (collectMakeStaticArgs)
import GHC.Core.DataCon
import GHC.Core.Make (mkStringExprFSWith,MkStringIds(..))
import GHC.Core.Type

import GHC.Cmm.CLabel

import GHC.Unit.Module
import GHC.Utils.Outputable as Outputable

import GHC.Linker.Types

import GHC.Types.Id
import GHC.Types.ForeignStubs
import GHC.Data.Maybe
import GHC.Data.FastString

import Control.Monad.Trans.State.Strict
import Data.List (intercalate)
import GHC.Fingerprint

data StaticPtrOpts = StaticPtrOpts
  { opt_platform                :: !Platform    -- ^ Target platform
  , opt_gen_cstub               :: !Bool        -- ^ Generate CStub or not
  , opt_mk_string               :: !MkStringIds -- ^ Ids for `unpackCString[Utf8]#`
  , opt_static_ptr_info_datacon :: !DataCon          -- ^ `StaticPtrInfo` datacon
  , opt_static_ptr_datacon      :: !DataCon          -- ^ `StaticPtr` datacon
  }

-- | Replaces all bindings of the form
--
-- > b = /\ ... -> makeStatic location value
--
--  with
--
-- > b = /\ ... ->
-- >   StaticPtr key (StaticPtrInfo "pkg key" "module" location) value
--
--  where a distinct key is generated for each binding.
--
-- It also yields the C stub that inserts these bindings into the static
-- pointer table.
sptCreateStaticBinds :: StaticPtrOpts -> Module -> CoreProgram -> IO ([SptEntry], Maybe CStub, CoreProgram)
sptCreateStaticBinds opts this_mod binds = do
      (fps, binds') <- evalStateT (go [] [] binds) 0
      let cstub
            | opt_gen_cstub opts = Just (sptModuleInitCode (opt_platform opts) this_mod fps)
            | otherwise          = Nothing
      return (fps, cstub, binds')
  where
    go fps bs xs = case xs of
      []        -> return (reverse fps, reverse bs)
      bnd : xs' -> do
        (fps', bnd') <- replaceStaticBind bnd
        go (reverse fps' ++ fps) (bnd' : bs) xs'

    -- Generates keys and replaces 'makeStatic' with 'StaticPtr'.
    --
    -- The 'Int' state is used to produce a different key for each binding.
    replaceStaticBind :: CoreBind
                      -> StateT Int IO ([SptEntry], CoreBind)
    replaceStaticBind (NonRec b e) = do (mfp, (b', e')) <- replaceStatic b e
                                        return (maybeToList mfp, NonRec b' e')
    replaceStaticBind (Rec rbs) = do
      (mfps, rbs') <- unzip <$> mapM (uncurry replaceStatic) rbs
      return (catMaybes mfps, Rec rbs')

    replaceStatic :: Id -> CoreExpr
                  -> StateT Int IO (Maybe SptEntry, (Id, CoreExpr))
    replaceStatic b e@(collectTyBinders -> (tvs, e0)) =
      case collectMakeStaticArgs e0 of
        Nothing      -> return (Nothing, (b, e))
        Just (_, t, info, arg) -> do
          (fp, e') <- mkStaticBind t info arg
          return (Just (SptEntry b fp), (b, foldr Lam e' tvs))

    mkStaticBind :: Type -> CoreExpr -> CoreExpr
                 -> StateT Int IO (Fingerprint, CoreExpr)
    mkStaticBind t srcLoc e = do
      i <- get
      put (i + 1)
      let staticPtrInfoDataCon = opt_static_ptr_info_datacon opts
      let fp@(Fingerprint w0 w1) = mkStaticPtrFingerprint i
      let mk_string_fs = mkStringExprFSWith (opt_mk_string opts)
      let info = mkConApp staticPtrInfoDataCon
                  [ mk_string_fs $ unitFS $ moduleUnit this_mod
                  , mk_string_fs $ moduleNameFS $ moduleName this_mod
                  , srcLoc
                  ]

      let staticPtrDataCon = opt_static_ptr_datacon opts
      return (fp, mkConApp staticPtrDataCon
                               [ Type t
                               , mkWord64LitWord64 w0
                               , mkWord64LitWord64 w1
                               , info
                               , e ])

    mkStaticPtrFingerprint :: Int -> Fingerprint
    mkStaticPtrFingerprint n = fingerprintString $ intercalate ":"
        [ unitString $ moduleUnit this_mod
        , moduleNameString $ moduleName this_mod
        , show n
        ]

-- | @sptModuleInitCode module fps@ is a C stub to insert the static entries
-- of @module@ into the static pointer table.
--
-- @fps@ is a list associating each binding corresponding to a static entry with
-- its fingerprint.
sptModuleInitCode :: Platform -> Module -> [SptEntry] -> CStub
sptModuleInitCode platform this_mod entries
    -- no CStub if there is no entry
  | [] <- entries                           = mempty
    -- no CStub for the JS backend: it deals with it directly during JS code
    -- generation
  | ArchJavaScript <- platformArch platform = mempty
  | otherwise =
    initializerCStub platform init_fn_nm empty init_fn_body `mappend`
    finalizerCStub platform fini_fn_nm empty fini_fn_body
  where
    init_fn_nm = mkInitializerStubLabel this_mod (fsLit "spt")
    init_fn_body = vcat
        [  text "static StgWord64 k" <> int i <> text "[2] = "
           <> pprFingerprint fp <> semi
        $$ text "extern StgPtr "
           <> (pprCLabel platform $ mkClosureLabel (idName n) (idCafInfo n)) <> semi
        $$ text "hs_spt_insert" <> parens
             (hcat $ punctuate comma
                [ char 'k' <> int i
                , char '&' <> pprCLabel platform (mkClosureLabel (idName n) (idCafInfo n))
                ]
             )
        <> semi
        |  (i, SptEntry n fp) <- zip [0..] entries
        ]

    fini_fn_nm = mkFinalizerStubLabel this_mod (fsLit "spt")
    fini_fn_body = vcat
        [  text "StgWord64 k" <> int i <> text "[2] = "
           <> pprFingerprint fp <> semi
        $$ text "hs_spt_remove" <> parens (char 'k' <> int i) <> semi
        | (i, (SptEntry _ fp)) <- zip [0..] entries
        ]

    pprFingerprint :: Fingerprint -> SDoc
    pprFingerprint (Fingerprint w1 w2) =
      braces $ hcat $ punctuate comma
                 [ integer (fromIntegral w1) <> text "ULL"
                 , integer (fromIntegral w2) <> text "ULL"
                 ]
