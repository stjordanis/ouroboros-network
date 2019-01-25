{ system, compiler, flags, pkgs, hsPkgs, pkgconfPkgs, ... }:
  {
    flags = {};
    package = {
      specVersion = "1.10";
      identifier = { name = "iohk-monitoring"; version = "0.1.0.0"; };
      license = "MIT";
      copyright = "2018 IOHK";
      maintainer = "";
      author = "Alexander Diemand, Andreas Triantafyllos";
      homepage = "";
      url = "";
      synopsis = "loggin, benchmarking and monitoring framework";
      description = "";
      buildType = "Simple";
      };
    components = {
      "library" = {
        depends = [
          (hsPkgs.base)
          (hsPkgs.aeson)
          (hsPkgs.array)
          (hsPkgs.async)
          (hsPkgs.auto-update)
          (hsPkgs.bytestring)
          (hsPkgs.clock)
          (hsPkgs.containers)
          (hsPkgs.contravariant)
          (hsPkgs.directory)
          (hsPkgs.ekg)
          (hsPkgs.ekg-core)
          (hsPkgs.exceptions)
          (hsPkgs.filepath)
          (hsPkgs.katip)
          (hsPkgs.lens)
          (hsPkgs.mtl)
          (hsPkgs.safe-exceptions)
          (hsPkgs.stm)
          (hsPkgs.template-haskell)
          (hsPkgs.text)
          (hsPkgs.time)
          (hsPkgs.time-units)
          (hsPkgs.transformers)
          (hsPkgs.unordered-containers)
          (hsPkgs.yaml)
          ] ++ (if system.isWindows
          then [ (hsPkgs.Win32) ]
          else [ (hsPkgs.unix) ]);
        };
      exes = {
        "example-simple" = {
          depends = [
            (hsPkgs.base)
            (hsPkgs.iohk-monitoring)
            (hsPkgs.async)
            (hsPkgs.bytestring)
            (hsPkgs.mtl)
            (hsPkgs.unix)
            ];
          };
        };
      tests = {
        "tests" = {
          depends = [
            (hsPkgs.base)
            (hsPkgs.iohk-monitoring)
            (hsPkgs.array)
            (hsPkgs.bytestring)
            (hsPkgs.clock)
            (hsPkgs.containers)
            (hsPkgs.mtl)
            (hsPkgs.process)
            (hsPkgs.QuickCheck)
            (hsPkgs.random)
            (hsPkgs.semigroups)
            (hsPkgs.stm)
            (hsPkgs.tasty)
            (hsPkgs.tasty-hunit)
            (hsPkgs.tasty-quickcheck)
            (hsPkgs.text)
            (hsPkgs.time)
            (hsPkgs.time-units)
            (hsPkgs.transformers)
            (hsPkgs.void)
            ];
          };
        };
      };
    } // {
    src = (pkgs.lib).mkDefault (pkgs.fetchgit {
      url = "https://github.com/input-output-hk/iohk-monitoring-framework";
      rev = "e53ea548a8d75de01e45d703a5c1afa6846d2daf";
      sha256 = "15ilpp5z4sldxm194riakx7ggilqcm5ylghc8jlxkm5djqk8hlqv";
      });
    }