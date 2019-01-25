{ system, compiler, flags, pkgs, hsPkgs, pkgconfPkgs, ... }:
  {
    flags = {};
    package = {
      specVersion = "1.10";
      identifier = { name = "ouroboros-network"; version = "0.1.0.0"; };
      license = "NONE";
      copyright = "2018 IOHK";
      maintainer = "";
      author = "Alexander Vieth, Marcin Szamotulski, Duncan Coutts";
      homepage = "";
      url = "";
      synopsis = "A networking layer for the Ouroboros blockchain protocol";
      description = "";
      buildType = "Simple";
      };
    components = {
      "library" = {
        depends = [
          (hsPkgs.base)
          (hsPkgs.typed-transitions)
          (hsPkgs.io-sim-classes)
          (hsPkgs.array)
          (hsPkgs.async)
          (hsPkgs.bytestring)
          (hsPkgs.cborg)
          (hsPkgs.containers)
          (hsPkgs.fingertree)
          (hsPkgs.hashable)
          (hsPkgs.iohk-monitoring)
          (hsPkgs.mtl)
          (hsPkgs.network)
          (hsPkgs.pipes)
          (hsPkgs.process)
          (hsPkgs.serialise)
          (hsPkgs.stm)
          (hsPkgs.text)
          (hsPkgs.QuickCheck)
          ];
        };
      tests = {
        "tests" = {
          depends = [
            (hsPkgs.base)
            (hsPkgs.ouroboros-network)
            (hsPkgs.typed-transitions)
            (hsPkgs.io-sim-classes)
            (hsPkgs.io-sim)
            (hsPkgs.array)
            (hsPkgs.bytestring)
            (hsPkgs.cborg)
            (hsPkgs.containers)
            (hsPkgs.free)
            (hsPkgs.fingertree)
            (hsPkgs.free)
            (hsPkgs.mtl)
            (hsPkgs.pipes)
            (hsPkgs.process)
            (hsPkgs.QuickCheck)
            (hsPkgs.serialise)
            (hsPkgs.tasty)
            (hsPkgs.tasty-quickcheck)
            (hsPkgs.text)
            ];
          };
        };
      };
    } // rec { src = (pkgs.lib).mkDefault .././../ouroboros-network; }