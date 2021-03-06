-- | Take configuration, produce 'Travis'.
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-unused-matches #-}
module HaskellCI.Travis (
    makeTravis,
    travisHeader,
    ) where

import Control.Applicative  ((<|>))
import Control.Monad        (unless, when)
import Data.Foldable        (for_, toList, traverse_)
import Data.Generics.Labels ()
import Data.List            (foldl', intercalate, nub)
import Data.Maybe           (fromMaybe, isJust)
import Data.Set             (Set)
import Lens.Micro
import Data.Void (Void)

import qualified Data.Map.Strict                               as M
import qualified Data.Set                                      as S
import qualified Distribution.FieldGrammar                     as C
import qualified Distribution.FieldGrammar.Pretty3             as C3
import qualified Distribution.Fields.Pretty                    as C
import qualified Distribution.Package                          as C
import qualified Distribution.PackageDescription               as C
import qualified Distribution.PackageDescription.Configuration as C
import qualified Distribution.PackageDescription.FieldGrammar  as C
import qualified Distribution.ParseUtils                       as PU (showToken)
import qualified Distribution.Pretty                           as C
import qualified Distribution.Types.GenericPackageDescription  as C
import qualified Distribution.Types.SourceRepo                 as C
import qualified Distribution.Types.VersionRange               as C
import qualified Distribution.Version                          as C
import qualified Text.PrettyPrint                              as PP

import qualified Distribution.Types.BuildInfo.Lens          as L
import qualified Distribution.Types.PackageDescription.Lens as L

import HaskellCI.Cli
import HaskellCI.Config
import HaskellCI.Config.ConstraintSet
import HaskellCI.Config.CopyFields
import HaskellCI.Config.Doctest
import HaskellCI.Config.Folds
import HaskellCI.MonadErr
import HaskellCI.Config.HLint
import HaskellCI.Config.Installed
import HaskellCI.Config.Jobs
import HaskellCI.GHC
import HaskellCI.Jobs
import HaskellCI.List
import HaskellCI.Optimization
import HaskellCI.Package
import HaskellCI.Project
import HaskellCI.Sh
import HaskellCI.Tools
import HaskellCI.Travis.Yaml
import HaskellCI.Version

-------------------------------------------------------------------------------
-- Travis header
-------------------------------------------------------------------------------

travisHeader :: Bool -> [String] -> [String]
travisHeader insertVersion argv =
    [ "This Travis job script has been generated by a script via"
    , ""
    , "  haskell-ci " ++ unwords [ "'" ++ a ++ "'" | a <- argv ]
    , ""
    , "For more information, see https://github.com/haskell-CI/haskell-ci"
    , ""
    ] ++
    if insertVersion then
    [ "version: " ++ haskellCIVerStr
    , ""
    ] else []

-------------------------------------------------------------------------------
-- Generate travis configuration
-------------------------------------------------------------------------------

makeTravis
    :: [String]
    -> Config
    -> Project Void Package
    -> JobVersions
    -> Either ShError Travis -- TODO: writer
makeTravis argv Config {..} prj JobVersions {..} = do
    -- before caching: clear some redundant stuff
    beforeCache <- runSh $ when cfgCache $ do
        sh "rm -fv $CABALHOME/packages/hackage.haskell.org/build-reports.log"
        comment "remove files that are regenerated by 'cabal update'"
        sh "rm -fv $CABALHOME/packages/hackage.haskell.org/00-index.*" -- legacy
        sh "rm -fv $CABALHOME/packages/hackage.haskell.org/*.json" -- TUF meta-data
        sh "rm -fv $CABALHOME/packages/hackage.haskell.org/01-index.cache"
        sh "rm -fv $CABALHOME/packages/hackage.haskell.org/01-index.tar"
        sh "rm -fv $CABALHOME/packages/hackage.haskell.org/01-index.tar.idx"
        sh "rm -rfv $CABALHOME/packages/head.hackage" -- if we cache, it will break builds.

    -- before install: we set up the environment, install GHC/cabal on OSX
    beforeInstall <- runSh $ do
        sh "HC=$(echo \"/opt/$CC/bin/ghc\" | sed 's/-/\\//')"
        sh "HCPKG=\"$HC-pkg\""
        sh "unset CC"
        -- cabal
        sh "CABAL=/opt/ghc/bin/cabal"
        sh "CABALHOME=$HOME/.cabal"
        -- PATH
        sh "export PATH=\"$CABALHOME/bin:$PATH\""
        -- rootdir is useful for manual script additions
        sh "TOP=$(pwd)"
        -- macOS installing
        let haskellOnMacos = "https://haskell.futurice.com/haskell-on-macos.py"
        unless (null cfgOsx) $ do
            sh $ "if [ \"$TRAVIS_OS_NAME\" = \"osx\" ]; then brew update; brew upgrade python@3; curl " ++ haskellOnMacos ++ " | python3 - --make-dirs --install-dir=$HOME/.ghc-install --cabal-alias=head install cabal-install-head ${TRAVIS_COMPILER}; fi"
            sh' [2034,2039] "if [ \"$TRAVIS_OS_NAME\" = \"osx\" ]; then HC=$HOME/.ghc-install/ghc/bin/$TRAVIS_COMPILER; HCPKG=${HC/ghc/ghc-pkg}; CABAL=$HOME/.ghc-install/ghc/bin/cabal; fi"
        -- HCNUMVER, numeric HC version, e.g. ghc 7.8.4 is 70804 and 7.10.3 is 71003
        sh "HCNUMVER=$(( $(${HC} --numeric-version|sed -E 's/([0-9]+)\\.([0-9]+)\\.([0-9]+).*/\\1 * 10000 + \\2 * 100 + \\3/') ))"
        sh "echo $HCNUMVER"
        -- verbose in .cabal/config is not respected
        -- https://github.com/haskell/cabal/issues/5956
        sh "CABAL=\"$CABAL -vnormal+nowrap+markoutput\""

        -- Color cabal output
        when cfgColor $ do
            cat' ".colorful.awk"
                [ "function blue(s) { printf \"\\033[0;34m\" s \"\\033[0m \" }"
                , "BEGIN { state = \"output\"; }"
                , "/^-----BEGIN CABAL OUTPUT-----$/ { state = \"cabal\" }"
                , "/^-----END CABAL OUTPUT-----$/ { state = \"output\" }"
                , "!/^(-----BEGIN CABAL OUTPUT-----|-----END CABAL OUTPUT-----)/ {"
                , "  if (state == \"cabal\") {"
                , "    print blue($0)"
                , "  } else {"
                , "    print $0"
                , "  }"
                , "}"
                ]
            sh "cat .colorful.awk"
            sh $ unlines
                [ "color_cabal_output () {"
                , "  awk -f $TOP/.colorful.awk"
                , "}"
                ]
            sh "echo text | color_cabal_output"

    -- in install step we install tools and dependencies
    install <- runSh $ do
        sh "${CABAL} --version"
        sh "echo \"$(${HC} --version) [$(${HC} --print-project-git-commit-id 2> /dev/null || echo '?')]\""
        sh "TEST=--enable-tests"
        shForJob (C.invertVersionRange cfgTests) "TEST=--disable-tests"
        sh "BENCH=--enable-benchmarks"
        shForJob (C.invertVersionRange cfgBenchmarks) "BENCH=--disable-benchmarks"
        sh "HEADHACKAGE=${HEADHACKAGE-false}"

        -- create ~/.cabal/config
        sh "rm -f $CABALHOME/config"
        cat "$CABALHOME/config"
            [ "verbose: normal +nowrap +markoutput" -- https://github.com/haskell/cabal/issues/5956
            , "remote-build-reporting: anonymous"
            , "write-ghc-environment-files: always"
            , "remote-repo-cache: $CABALHOME/packages"
            , "logs-dir:          $CABALHOME/logs"
            , "world-file:        $CABALHOME/world"
            , "extra-prog-path:   $CABALHOME/bin"
            , "symlink-bindir:    $CABALHOME/bin"
            , "installdir:        $CABALHOME/bin"
            , "build-summary:     $CABALHOME/logs/build.log"
            , "store-dir:         $CABALHOME/store"
            , "install-dirs user"
            , "  prefix: $CABALHOME"
            , "repository hackage.haskell.org"
            , "  url: http://hackage.haskell.org/"
            ]

        -- Add head.hackage repository to ~/.cabal/config
        -- (locally you want to add it to cabal.project)
        unless (S.null headGhcVers) $ sh $ unlines $
            [ "if $HEADHACKAGE; then"
            , "echo \"allow-newer: $($HCPKG list --simple-output | sed -E 's/([a-zA-Z-]+)-[0-9.]+/*:\\1/g')\" >> $CABALHOME/config"
            ] ++
            lines (catCmd Double "$CABALHOME/config"
            [ "repository head.hackage.ghc.haskell.org"
            , "   url: https://ghc.gitlab.haskell.org/head.hackage/"
            , "   secure: True"
            , "   root-keys: 7541f32a4ccca4f97aea3b22f5e593ba2c0267546016b992dfadcd2fe944e55d"
            , "              26021a13b401500c8eb2761ca95c61f2d625bfef951b939a8124ed12ecf07329"
            , "              f76d08be13e9a61a377a85e2fb63f4c5435d40f8feb3e12eb05905edb8cdea89"
            , "   key-threshold: 3"
            ]) ++
            [ "fi"
            ]

        -- Cabal jobs
        for_ (cfgJobs >>= cabalJobs) $ \n ->
            sh $ "echo 'jobs: " ++ show n ++ "' >> $CABALHOME/config"

        -- GHC jobs
        for_ (cfgJobs >>= ghcJobs) $ \m -> do
            catForJob (C.orLaterVersion (C.mkVersion [7,8])) "$CABALHOME/config"
                [ "program-default-options"
                , "  ghc-options: -j" ++ show m
                ]

        sh "cat $CABALHOME/config"

        -- remove project own cabal.project files
        sh "rm -fv cabal.project cabal.project.local cabal.project.freeze"

        -- Update hackage index.
        sh "travis_retry ${CABAL} v2-update -v"

        -- Install doctest
        let doctestVersionConstraint
                | C.isAnyVersion (cfgDoctestVersion cfgDoctest) = ""
                | otherwise = " --constraint='doctest " ++ C.prettyShow (cfgDoctestVersion cfgDoctest) ++ "'"
        when doctestEnabled $
            shForJob (cfgDoctestEnabled cfgDoctest `C.intersectVersionRanges` doctestJobVersionRange) $
                cabal $ "v2-install -w ${HC} -j2 doctest" ++ doctestVersionConstraint

        -- Install hlint
        let hlintVersionConstraint
                | C.isAnyVersion (cfgHLintVersion cfgHLint) = ""
                | otherwise = " --constraint='hlint " ++ C.prettyShow (cfgHLintVersion cfgHLint) ++ "'"
        when (cfgHLintEnabled cfgHLint) $ shForJob (hlintJobVersionRange versions (cfgHLintJob cfgHLint)) $
            cabal $ "v2-install -w ${HC} -j2 hlint" ++ hlintVersionConstraint

        -- create cabal.project file
        generateCabalProject False

        -- autoreconf
        for_ pkgs $ \Pkg{pkgDir} ->
            sh $ "if [ -f \"" ++ pkgDir ++ "/configure.ac\" ]; then (cd \"" ++ pkgDir ++ "\" && autoreconf -i); fi"

        -- dump install plan
        sh $ cabal "v2-freeze -w ${HC} ${TEST} ${BENCH}"
        sh "cat cabal.project.freeze | sed -E 's/^(constraints: *| *)//' | sed 's/any.//'"
        sh "rm  cabal.project.freeze"

        -- Install dependencies
        when cfgInstallDeps $ do
            -- install dependencies
            sh $ cabal "v2-build -w ${HC} ${TEST} ${BENCH} --dep -j2 all"

            -- install dependencies for no-test-no-bench
            shForJob cfgNoTestsNoBench $ cabal "v2-build -w ${HC} --disable-tests --disable-benchmarks --dep -j2 all"

    -- Here starts the actual work to be performed for the package under test;
    -- any command which exits with a non-zero exit code causes the build to fail.
    script <- runSh $ do
        sh "DISTDIR=$(mktemp -d /tmp/dist-test.XXXX)"

        -- sdist
        foldedSh FoldSDist "Packaging..." cfgFolds $ do
            sh $ cabal "v2-sdist all"

        -- unpack
        foldedSh FoldUnpack "Unpacking..." cfgFolds $ do
            sh "mv dist-newstyle/sdist/*.tar.gz ${DISTDIR}/"
            sh "cd ${DISTDIR} || false" -- fail explicitly, makes SC happier
            sh "find . -maxdepth 1 -name '*.tar.gz' -exec tar -xvf '{}' \\;"

            generateCabalProject True

        -- build no-tests no-benchmarks
        unless (equivVersionRanges C.noVersion cfgNoTestsNoBench) $ foldedSh FoldBuild "Building..." cfgFolds $ do
            comment "this builds all libraries and executables (without tests/benchmarks)"
            shForJob cfgNoTestsNoBench $ cabal "v2-build -w ${HC} --disable-tests --disable-benchmarks all"

        -- build everything
        foldedSh FoldBuildEverything "Building with tests and benchmarks..." cfgFolds $ do
            comment "build & run tests, build benchmarks"
            sh $ cabal "v2-build -w ${HC} ${TEST} ${BENCH} all"

        -- cabal v2-test fails if there are no test-suites.
        foldedSh FoldTest "Testing..." cfgFolds $ do
            shForJob (C.intersectVersionRanges cfgTests $ C.intersectVersionRanges cfgRunTests hasTests) $
                cabal "v2-test -w ${HC} ${TEST} ${BENCH} all"

        -- doctest
        when doctestEnabled $ foldedSh FoldDoctest "Doctest..." cfgFolds $ do
            let doctestOptions = unwords $ cfgDoctestOptions cfgDoctest
            unless (null $ cfgDoctestFilterPkgs cfgDoctest) $ do
                sh $ unlines $ concat
                    [ [ "for ghcenv in .ghc.environment.*; do"
                      , "mv $ghcenv ghcenv;"
                      ]
                    , cfgDoctestFilterPkgs cfgDoctest <&> \pn ->
                        "grep -vE '^package-id " ++ C.unPackageName pn ++ "-([0-9]+(\\.[0-9]+)*)-' ghcenv > ghcenv.tmp; mv ghcenv.tmp ghcenv;"
                    , [ "mv ghcenv $ghcenv;"
                      , "cat $ghcenv;"
                      , "done"
                      ]
                    ]
            for_ pkgs $ \Pkg{pkgName,pkgGpd,pkgJobs} -> do
                for_ (doctestArgs pkgGpd) $ \args -> do
                    let args' = unwords args
                    let vr = cfgDoctestEnabled cfgDoctest `C.intersectVersionRanges` doctestJobVersionRange `C.intersectVersionRanges` pkgJobs
                    unless (null args) $ shForJob  vr $
                        "(cd " ++ pkgName ++ "-* && doctest " ++ doctestOptions ++ " " ++ args' ++ ")"

        -- hlint
        when (cfgHLintEnabled cfgHLint) $ foldedSh FoldHLint "HLint.." cfgFolds $ do
            let "" <+> ys = ys
                xs <+> "" = xs
                xs <+> ys = xs ++ " " ++ ys

                prependSpace "" = ""
                prependSpace xs = " " ++ xs

            let hlintOptions = prependSpace $ maybe "" ("-h ${TOP}/" ++) (cfgHLintYaml cfgHLint) <+> unwords (cfgHLintOptions cfgHLint)

            for_ pkgs $ \Pkg{pkgName,pkgGpd,pkgJobs} -> do
                for_ (hlintArgs pkgGpd) $ \args -> do
                    let args' = unwords args
                    unless (null args) $
                        shForJob (hlintJobVersionRange versions (cfgHLintJob cfgHLint) `C.intersectVersionRanges` pkgJobs) $
                        "(cd " ++ pkgName ++ "-* && hlint" ++ hlintOptions ++ " " ++ args' ++ ")"

        -- cabal check
        when cfgCheck $ foldedSh FoldCheck "cabal check..." cfgFolds $ do
            for_ pkgs $ \Pkg{pkgName,pkgJobs} -> shForJob pkgJobs $
                "(cd " ++ pkgName ++ "-* && ${CABAL} -vnormal check)"

        -- haddock
        when (hasLibrary && not (equivVersionRanges C.noVersion cfgHaddock)) $
            foldedSh FoldHaddock "haddock..." cfgFolds $
                shForJob cfgHaddock $ cabal "v2-haddock -w ${HC} ${TEST} ${BENCH} all"

        -- unconstained build
        -- Have to build last, as we remove cabal.project.local
        unless (equivVersionRanges C.noVersion cfgUnconstrainted) $
            foldedSh FoldBuildInstalled "Building without installed constraints for packages in global-db..." cfgFolds $ do
                shForJob cfgUnconstrainted "rm -f cabal.project.local"
                shForJob cfgUnconstrainted $ cabal "v2-build -w ${HC} --disable-tests --disable-benchmarks all"

        -- and now, as we don't have cabal.project.local;
        -- we can test with other constraint sets
        unless (null cfgConstraintSets) $ do
            comment "Constraint sets"
            sh "rm -rf cabal.project.local"

            for_ cfgConstraintSets $ \cs -> do
                let name            = csName cs
                let shForCs         = shForJob (csGhcVersions cs)
                let testFlag        = if csTests cs then "--enable-tests" else "--disable-tests"
                let benchFlag       = if csBenchmarks cs then "--enable-benchmarks" else "--disable-benchmarks"
                let constraintFlags = map (\x ->  "--constraint='" ++ x ++ "'") (csConstraints cs)
                let allFlags        = unwords (testFlag : benchFlag : constraintFlags)

                foldedSh' FoldConstraintSets name ("Constraint set " ++ name) cfgFolds $ do
                    shForCs $ cabal $ "v2-build -w ${HC} " ++ allFlags ++ " all"
                    when (csRunTests cs) $
                        shForCs $ cabal $ "v2-test -w ${HC} " ++ allFlags ++ " all"
                    when (csHaddock cs) $
                        shForCs $ cabal $ "v2-haddock -w ${HC} " ++ allFlags ++ " all"

    -- assemble travis configuration
    return Travis
        { travisLanguage      = "c"
        , travisDist          = "xenial"
        , travisGit           = TravisGit
            { tgSubmodules = False
            }
        , travisCache         = TravisCache
            { tcDirectories = buildList $ when cfgCache $ do
                item "$HOME/.cabal/packages"
                item "$HOME/.cabal/store"
                -- on OSX ghc is installed in $HOME so we can cache it
                -- independently of linux
                when (cfgCache && not (null cfgOsx)) $ do
                    item "$HOME/.ghc-install"
            }
        , travisBranches      = TravisBranches
            { tbOnly = cfgOnlyBranches
            }
        , travisNotifications = TravisNotifications
            { tnIRC = justIf (not $ null cfgIrcChannels) $ TravisIRC
                { tiChannels = cfgIrcChannels
                , tiSkipJoin = True
                , tiTemplate =
                    [ "\"\\x0313" ++ projectName ++ "\\x03/\\x0306%{branch}\\x03 \\x0314%{commit}\\x03 %{build_url} %{message}\""
                    ]
                }
            }
        , travisServices      = buildList $ do
            when cfgPostgres $ item "postgresql"
        , travisAddons        = TravisAddons
            { taApt      = TravisApt [] []
            , taPostgres = if cfgPostgres then Just "10" else Nothing
            }
        , travisMatrix        = TravisMatrix
            { tmInclude = buildList $ do
                let tellJob :: Bool -> Maybe C.Version -> ListBuilder TravisJob ()
                    tellJob osx gv = do
                        let cvs = dispGhcVersion $ gv >>= correspondingCabalVersion cfgCabalInstallVersion
                        let gvs = dispGhcVersion gv
                        let pre | previewGHC cfgHeadHackage gv = Just "HEADHACKAGE=true"
                                | otherwise                    = Nothing

                        item TravisJob
                            { tjCompiler = "ghc-" ++ gvs
                            , tjOS       = if osx then "osx" else "linux"
                            , tjEnv      = (gv >>= \v -> M.lookup v cfgEnv) <|> pre
                            , tjAddons   = TravisAddons
                                { taApt = TravisApt
                                    { taPackages = ("ghc-" ++ gvs) : ("cabal-install-" ++ cvs) : S.toList cfgApt
                                    , taSources  = ["hvr-ghc"]
                                    }
                                , taPostgres = Nothing
                                }
                            }

                for_ (reverse $ S.toList versions) $ tellJob False
                for_ (reverse $ S.toList osxVersions) $ tellJob True . Just

            , tmAllowFailures =
                [ TravisAllowFailure $ "ghc-" ++ dispGhcVersion compiler
                | compiler <- S.toList $ headGhcVers `S.union` S.map Just (S.filter (`C.withinRange` cfgAllowFailures) versions')
                ]
            }
        , travisBeforeCache   = beforeCache
        , travisBeforeInstall = beforeInstall
        , travisInstall       = install
        , travisScript        = script
        }
  where
    pkgs = prjPackages prj
    projectName = fromMaybe (pkgName $ head pkgs) cfgProjectName

    justIf True x  = Just x
    justIf False _ = Nothing

    -- TODO: should this be part of MonadSh ?
    foldedSh label = foldedSh' label ""

    -- https://github.com/travis-ci/docs-travis-ci-com/issues/949#issuecomment-276755003
    -- https://github.com/travis-ci/travis-rubies/blob/9f7962a881c55d32da7c76baefc58b89e3941d91/build.sh#L38-L44
    -- https://github.com/travis-ci/travis-build/blob/91bf066/lib/travis/build/shell/dsl.rb#L58-L63
    foldedSh' :: Fold -> String -> String -> Set Fold -> ShM () -> ShM ()
    foldedSh' label sfx plabel labels block
        | label `S.notMember` labels = commentedBlock plabel block
        | otherwise = case runSh block of
            Left err  -> throwErr err
            Right shs
                | all isComment shs -> pure ()
                | otherwise         -> ShM $ \shs1 -> Right $
                    ( shs1
                    . (Comment plabel :)
                    . (Sh ("echo '" ++ plabel ++ "' && echo -en 'travis_fold:start:" ++ label' ++ "\\\\r'") :)
                    . (shs ++)
                    . (Sh ("echo -en 'travis_fold:end:" ++ label' ++ "\\\\r'") :)
                    -- return ()
                    , ()
                    )
      where
        label' | null sfx  = showFold label
               | otherwise = showFold label ++ "-" ++ sfx

    doctestEnabled = any (`C.withinRange` cfgDoctestEnabled cfgDoctest) versions'

    -- version range which has tests
    hasTests :: C.VersionRange
    hasTests = foldr C.unionVersionRanges C.noVersion
        [ pkgJobs
        | Pkg{pkgGpd,pkgJobs} <- pkgs
        , not $ null $ C.condTestSuites pkgGpd
        ]

    hasLibrary = any (\Pkg{pkgGpd} -> isJust $ C.condLibrary pkgGpd) pkgs

    -- GHC versions which need head.hackage
    headGhcVers :: Set (Maybe C.Version)
    headGhcVers = S.filter (previewGHC cfgHeadHackage) versions

    cabal :: String -> String
    cabal cmd | cfgColor  = cabalCmd ++ " | color_cabal_output"
              | otherwise = cabalCmd
      where
        cabalCmd = "${CABAL} " ++ cmd

    forJob :: C.VersionRange -> String -> Maybe String
    forJob vr cmd
        | all (`C.withinRange` vr) versions'       = Just cmd
        | not $ any (`C.withinRange` vr) versions' = Nothing
        | otherwise                                = Just $ unwords
            [ "if"
            , ghcVersionPredicate vr
            , "; then"
            , cmd
            , "; fi"
            ]

    shForJob :: C.VersionRange -> String -> ShM ()
    shForJob vr cmd = maybe (pure ()) sh (forJob vr cmd)

    catForJob vr fp contents = shForJob vr (catCmd Double fp contents)

    generateCabalProjectFields :: Bool -> [C.PrettyField]
    generateCabalProjectFields dist = buildList $ do
        -- copy files from original cabal.project
        case cfgCopyFields of
            CopyFieldsNone -> pure ()
            CopyFieldsAll  -> traverse_ item (prjOrigFields prj)
            CopyFieldsSome -> do
                for_ (prjConstraints prj) $ \xs -> do
                    let s = concat (lines xs)
                    item $ C.PrettyField "constraints" $ PP.text s

                for_ (prjAllowNewer prj) $ \xs -> do
                    let s = concat (lines xs)
                    item $ C.PrettyField "allow-newer" $ PP.text s

                when (prjReorderGoals prj) $
                    item $ C.PrettyField "reorder-goals" $ PP.text "True"

                for_ (prjMaxBackjumps prj) $ \bj ->
                    item $ C.PrettyField "max-backjumps" $ PP.text $ show bj

                case prjOptimization prj of
                    OptimizationOn      -> return ()
                    OptimizationOff     -> item $ C.PrettyField "optimization" $ PP.text "False"
                    OptimizationLevel l -> item $ C.PrettyField "optimization" $ PP.text $ show l

                for_ (prjSourceRepos prj) $ \repo ->
                    item $ C.PrettySection "source-repository-package" [] $
                        C3.prettyFieldGrammar3 (C.sourceRepoFieldGrammar $ C.RepoKindUnknown "unused") repo

        -- local ghc-options
        unless (null cfgLocalGhcOptions) $ for_ pkgs $ \Pkg{pkgName} -> do
            let s = unwords $ map (show . PU.showToken) cfgLocalGhcOptions
            item $ C.PrettySection "package" [PP.text pkgName] $ buildList $
                item $ C.PrettyField "ghc-options" $ PP.text s

        -- raw-project is after local-ghc-options so we can override per package.
        traverse_ item cfgRawProject

    generateCabalProject :: Bool -> ShM ()
    generateCabalProject dist = do
        comment "Generate cabal.project"
        sh "rm -rf cabal.project cabal.project.local cabal.project.freeze"
        sh "touch cabal.project"

        sh $ unlines
            [ cmd
            | pkg <- pkgs
            , let p | dist      = pkgName pkg ++ "-*/*.cabal"
                    | otherwise = pkgDir pkg
            , cmd <- toList $ forJob (pkgJobs pkg) $
                "echo 'packages: \"" ++ p ++ "\"' >> cabal.project"
            ]

        cat "cabal.project" $ lines $ C.showFields' 2 $ generateCabalProjectFields dist

        -- also write cabal.project.local file with
        -- @
        -- constraints: base installed
        -- constraints: array installed
        -- ...
        --
        -- omitting any local package names
        case normaliseInstalled cfgInstalled of
            InstalledDiff pns -> sh $ unwords
                [ "for pkg in $($HCPKG list --simple-output); do"
                , "echo $pkg"
                , "| sed 's/-[^-]*$//'"
                , "| (grep -vE -- " ++ re ++ " || true)"
                , "| sed 's/^/constraints: /'"
                , "| sed 's/$/ installed/'"
                , ">> cabal.project.local; done"
                ]
              where
                pns' = S.map C.unPackageName pns `S.union` foldMap (S.singleton . pkgName) pkgs
                re = "'^(" ++ intercalate "|" (S.toList pns') ++ ")$'"

            InstalledOnly pns | not (null pns') -> sh' [2043] $ unwords
                [ "for pkg in " ++ unwords (S.toList pns') ++ "; do"
                , "echo \"constraints: $pkg installed\""
                , ">> cabal.project.local; done"
                ]
              where
                pns' = S.map C.unPackageName pns `S.difference` foldMap (S.singleton . pkgName) pkgs

            -- otherwise: nothing
            _ -> pure ()

        sh "cat cabal.project || true"
        sh "cat cabal.project.local || true"

data Quotes = Single | Double

escape :: Quotes -> String -> String
escape Single xs = "'" ++ concatMap f xs ++ "'" where
    f '\0' = ""
    f '\'' = "'\"'\"'"
    f x    = [x]
escape Double xs = show xs

catCmd :: Quotes -> FilePath -> [String] -> String
catCmd q fp contents = unlines
    [ "echo " ++ escape q l ++ replicate (maxLength - length l) ' ' ++ " >> " ++ fp
    | l <- contents
    ]
  where
    maxLength = foldl' (\a l -> max a (length l)) 0 contents
{-
-- https://travis-ci.community/t/multiline-commands-have-two-spaces-in-front-breaks-heredocs/2756
catCmd fp contents = unlines $
    [ "cat >> " ++ fp ++ " << HEREDOC" ] ++
    contents ++
    [ "HEREDOC" ]
-}

cat :: FilePath -> [String] -> ShM ()
cat fp contents = sh $ catCmd Double fp contents

cat' :: FilePath -> [String] -> ShM ()
cat' fp contents = sh' [2016, 2129] $ catCmd Single fp contents
-- SC2129: Consider using { cmd1; cmd2; } >> file instead of individual redirects
-- SC2016: Expressions don't expand in single quotes
-- that's the point!
