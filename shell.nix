{ pkgs ? import <nixpkgs> {} }:

let
  python = pkgs.python3.withPackages (ps: with ps; [
    pyserial
    pillow
    pypdf
  ]);
in
pkgs.mkShell {
  buildInputs = [
    python
    pkgs.gh
  ];
}
