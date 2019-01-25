{ system, compiler, flags, pkgs, hsPkgs, pkgconfPkgs, ... }:
  {
    flags = {};
    package = {
      specVersion = "1.10";
      identifier = { name = "ouroboros-consensus"; version = "0.1.0.0"; };
      license = "NONE";
      copyright = "2018 IOHK";
      maintainer = "operations@iohk.io";
      author = "IOHK Engineering Team";
      homepage = "";
      url = "";
      synopsis = "Consensus layer for the Ouroboros blockchain protocol";
      description = "";
      buildType = "Simple";
      };
    components = {
      "library" = {
        depends = [
          (hsPkgs.base)
          (hsPkgs.ouroboros-network)
          (hsPkgs.typed-transitions)
          (hsPkgs.io-sim-classes)
          (hsPkgs.base16-bytestring)
          (hsPkgs.bytestring)
          (hsPkgs.cborg)
          (hsPkgs.containers)
          (hsPkgs.cryptonite)
          (hsPkgs.directory)
          (hsPkgs.exceptions)
          (hsPkgs.filepath)
          (hsPkgs.fingertree)
          (hsPkgs.memory)
          (hsPkgs.mtl)
          (hsPkgs.pipes)
          (hsPkgs.serialise)
          (hsPkgs.stm)
          (hsPkgs.text)
          (hsPkgs.time)
          (hsPkgs.transformers)
          (hsPkgs.vector)
          (hsPkgs.QuickCheck)
          ] ++ (if system.isWindows
          then [ (hsPkgs.Win32) ]
          else [ (hsPkgs.unix) ]);
        };
      exes = {
        "demo-playground" = {
          depends = [
            (hsPkgs.base)
            (hsPkgs.typed-transitions)
            (hsPkgs.ouroboros-network)
            (hsPkgs.ouroboros-consensus)
            (hsPkgs.io-sim-classes)
            (hsPkgs.aeson)
            (hsPkgs.async)
            (hsPkgs.bytestring)
            (hsPkgs.cborg)
            (hsPkgs.containers)
            (hsPkgs.cryptonite)
            (hsPkgs.directory)
            (hsPkgs.mtl)
            (hsPkgs.optparse-applicative)
            (hsPkgs.serialise)
            (hsPkgs.stm)
            (hsPkgs.string-conv)
            (hsPkgs.text)
            (hsPkgs.time)
            ] ++ (if system.isWindows
            then [ (hsPkgs.Win32) ]
            else [ (hsPkgs.unix) ]);
          };
        };
      tests = {
        "test-consensus" = {
          depends = [
            (hsPkgs.base)
            (hsPkgs.typed-transitions)
            (hsPkgs.ouroboros-network)
            (hsPkgs.ouroboros-consensus)
            (hsPkgs.io-sim-classes)
            (hsPkgs.io-sim)
            (hsPkgs.containers)
            (hsPkgs.cryptonite)
            (hsPkgs.fgl)
            (hsPkgs.graphviz)
            (hsPkgs.mtl)
            (hsPkgs.QuickCheck)
            (hsPkgs.serialise)
            (hsPkgs.tasty)
            (hsPkgs.tasty-quickcheck)
            (hsPkgs.text)
            ];
          };
        "test-crypto" = {
          depends = [
            (hsPkgs.base)
            (hsPkgs.ouroboros-network)
            (hsPkgs.ouroboros-consensus)
            (hsPkgs.bytestring)
            (hsPkgs.QuickCheck)
            (hsPkgs.tasty)
            (hsPkgs.tasty-quickcheck)
            ];
          };
        "test-storage" = {
          depends = [
            (hsPkgs.base)
            (hsPkgs.ouroboros-network)
            (hsPkgs.ouroboros-consensus)
            (hsPkgs.io-sim-classes)
            (hsPkgs.bifunctors)
            (hsPkgs.bytestring)
            (hsPkgs.containers)
            (hsPkgs.directory)
            (hsPkgs.exceptions)
            (hsPkgs.generics-sop)
            (hsPkgs.mtl)
            (hsPkgs.pretty-show)
            (hsPkgs.QuickCheck)
            (hsPkgs.quickcheck-state-machine)
            (hsPkgs.random)
            (hsPkgs.tasty)
            (hsPkgs.tasty-hunit)
            (hsPkgs.tasty-quickcheck)
            (hsPkgs.temporary)
            (hsPkgs.transformers)
            (hsPkgs.tree-diff)
            ];
          };
        };
      };
    } // rec { src = (pkgs.lib).mkDefault .././../ouroboros-consensus; }