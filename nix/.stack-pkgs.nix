{
  overlay = hackage:
    {
      packages = {
        "cborg" = (((hackage.cborg)."0.2.1.0").revisions).default;
        "ekg" = (((hackage.ekg)."0.4.0.15").revisions).default;
        "ekg-core" = (((hackage.ekg-core)."0.1.1.6").revisions).default;
        "ekg-json" = (((hackage.ekg-json)."0.1.0.6").revisions).default;
        "fgl" = (((hackage.fgl)."5.7.0.1").revisions).default;
        "graphviz" = (((hackage.graphviz)."2999.20.0.3").revisions).default;
        "io-streams-haproxy" = (((hackage.io-streams-haproxy)."1.0.0.2").revisions).default;
        "katip" = (((hackage.katip)."0.6.3.0").revisions).default;
        "serialise" = (((hackage.serialise)."0.2.1.0").revisions).default;
        "snap-core" = (((hackage.snap-core)."1.0.3.2").revisions).default;
        "snap-server" = (((hackage.snap-server)."1.1.0.0").revisions).default;
        "QuickCheck" = (((hackage.QuickCheck)."2.12.6.1").revisions).default;
        "quickcheck-state-machine" = (((hackage.quickcheck-state-machine)."0.6.0").revisions).default;
        "time-units" = (((hackage.time-units)."1.0.0").revisions).default;
        "process" = (((hackage.process)."1.6.5.0").revisions).default;
        "containers" = (((hackage.containers)."0.5.11.0").revisions).default;
        "network" = (((hackage.network)."2.6.3.6").revisions).default;
        } // {
        ouroboros-consensus = ./.stack.nix/ouroboros-consensus.nix;
        typed-transitions = ./.stack.nix/typed-transitions.nix;
        ouroboros-network = ./.stack.nix/ouroboros-network.nix;
        io-sim = ./.stack.nix/io-sim.nix;
        io-sim-classes = ./.stack.nix/io-sim-classes.nix;
        iohk-monitoring = ./.stack.nix/iohk-monitoring.nix;
        clock = ./.stack.nix/clock.nix;
        transformers = ./.stack.nix/transformers.nix;
        };
      compiler.version = "8.4.4";
      compiler.nix-name = "ghc844";
      };
  resolver = "lts-13.3";
  compiler = "ghc-8.4.4";
  }
