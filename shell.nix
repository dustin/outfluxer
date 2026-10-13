{ pkgs ? import <nixpkgs> { } }:
with pkgs;
let
  hpkgs = haskellPackages;
  ghcWithDeps = hpkgs.ghcWithPackages (p: with p; [
    aeson
    async
    bytestring
    dhall
    influxdb
    lens
    monad-logger
    mtl
    net-mqtt
    network-uri
    optparse-applicative
    scientific
    text
    time
    transformers
    unliftio
    unliftio-core
    unordered-containers
    vector
    # test deps
    QuickCheck
    tasty
    tasty-hunit
    tasty-quickcheck
  ]);
in
mkShell {
  buildInputs = [
    ghcWithDeps
    stylish-haskell
    hlint
    ghcid
    hpkgs.haskell-language-server
    cabal-install
    hpack
    zlib
  ];

  shellHook = ''
    # ...
  '';
}
