{
  description = "SSHepherd Android development tools";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; config = { allowUnfree = true; android_sdk.accept_license = true; }; };
    android = pkgs.androidenv.composeAndroidPackages {
      platformVersions = [ "35" ];
      buildToolsVersions = [ "35.0.0" ];
      includeNDK = true;
      ndkVersions = [ "28.0.13004108" ];
      includeEmulator = false;
    };
    sdk = "${android.androidsdk}/libexec/android-sdk";
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.zig pkgs.stdenv.cc pkgs.curl pkgs.jdk17 pkgs.python3 pkgs.rustup pkgs.cargo-ndk android.androidsdk ];
      JAVA_HOME = "${pkgs.jdk17}";
      ANDROID_HOME = sdk;
      ANDROID_SDK_ROOT = sdk;
      ANDROID_NDK_HOME = "${sdk}/ndk/28.0.13004108";
    };
  };
}
