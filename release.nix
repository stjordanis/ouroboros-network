############################################################################
# Hydra release jobset
#
# Example build for Linux:
#
#   nix-build release.nix -A exes.demo-playground.x86_64-linux
#
# Example build for Windows (cross-compiled from Linux):
#
#   nix-build release.nix -A cross.exes.demo-playground.x86_64-linux
#
############################################################################

let
  iohkLib = import ./nix/iohk-common.nix {};
in {
    system ? builtins.currentSystem
  , config ? {}
  , pkgs ? iohkLib.pkgs
  , supportedSystems ? [ "x86_64-linux" "x86_64-darwin" ]
  , scrubJobs ? true
  , ouroboros-network ? { outPath = ./.; rev = "abcdef"; }
  , nixpkgsArgs ? {
      config = (import ./nix/config.nix // { allowUnfree = false; inHydra = true; });
      gitrev = ouroboros-network.rev;
    }
  }:

with (import (pkgs.path + "/pkgs/top-level/release-lib.nix") {
  inherit supportedSystems scrubJobs nixpkgsArgs;
  packageSet = import ouroboros-network.outPath;
});

let

  testJobs = mapTestOn {
    tests.test-consensus = supportedSystems;
    tests.test-crypto = supportedSystems;
    tests.test-storage = supportedSystems;

    haskellPackages.ouroboros-network.components.tests.tests = supportedSystems;
    haskellPackages.io-sim.components.tests.tests = supportedSystems;
    haskellPackages.typed-transitions.components.tests.test-typed-transitions = supportedSystems;
  };

  jobs = mapTestOn {
    exes.demo-playground =  supportedSystems;
  } // testJobs;

  crossJobs = mapTestOnCross lib.systems.examples.mingwW64 {
    exes.demo-playground = [ "x86_64-linux" ];
    tests.test-consensus = [ "x86_64-linux" ];
    tests.test-crypto    = [ "x86_64-linux" ];
    tests.test-storage   = [ "x86_64-linux" ];
    haskellPackages.ouroboros-network.components.tests.tests = [ "x86_64-linux" ];
  };

  requiredJobs = {
    required = pkgs.lib.hydraJob (pkgs.releaseTools.aggregate {
      name = "ouroboros-required-checks";
      constituents = [(lib.collect lib.isDerivation jobs)];
    });
  };



in
  jobs // requiredJobs
