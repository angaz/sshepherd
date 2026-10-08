# Reproducible tool shell: nix-shell scripts/ios-tools.nix
# nixpkgs 7a0f122f5090cf4c2ade2a13a0e229d4e19ba71f,
# sha256 0lbmglidppdwl8xxyrc77mlq2wsr0xnrgxxifp14ivr8k414i336.
let
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/7a0f122f5090cf4c2ade2a13a0e229d4e19ba71f.tar.gz";
    sha256 = "0lbmglidppdwl8xxyrc77mlq2wsr0xnrgxxifp14ivr8k414i336";
  };
  pkgs = import nixpkgs {};
# Use Xcode's compiler/SDK, not a Nix Darwin compiler wrapper.
in pkgs.mkShellNoCC {
  packages = [ pkgs.zig_0_16 ];
}
