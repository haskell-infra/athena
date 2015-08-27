import <nixpkgs/nixos/tests/make-test.nix> ({ pkgs, ... }: {
  name = "simple";
  description = "Trivial test";

  machine = { config, pkgs, ... }: {};

  testScript = ''
    startAll;
    $machine->waitForUnit("multi-user.target");
    $machine->succeed("true; true");
    $machine->shutdown;
  '';
})
