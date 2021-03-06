{ supportedSystems ? [ "x86_64-linux" "x86_64-darwin" ]
, nixpkgsArgs ? {
    config = { allowUnfree = false; inHydra = true; };
  }
}:
let nixpkgs = import ./nix/nixpkgs.nix {};
    rlib    = import (nixpkgs.path + "/pkgs/top-level/release-lib.nix")
    typed-transitions   = import ./typed-transitions/default.nix {};
    ouroboros-network   = import ./ouroboros-netowrk/default.nix {};
    ouroboros-consensus = import ./ouroboros-consensus/default.nix {};

    platforms = {
      typed-transitions = supportedSystems;
      ouroboros-network = supportedSystems;
      ouroboros-consensus = supportedSystemd;
    };
in rlib.mapTestOn platforms // ouroboros-network
