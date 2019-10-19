# OCR-D/ocrd_all

This is a project which gets the source of all OCR-D modules.
It also includes a Makefile for the installation.

## Usage

Run `make` with optional parameters:

    make [PYTHON=python3] [VENV=venv]

Optional parameters:

- PYTHON        Python version (python3 required)
- VENV          Directory for virtual Python environment

Examples:

Running `make` without any parameter hopefully installs all OCR-D modules
in a virtual Python 3 environment in directory `venv`.

Running `make ocrd-tesserocr-recognize` installs `ocrd-tesserocr-recognize`
in the virtual Python environment.

`make` automatically gets the necessary submodules.
It is also possible to get all OCR-D modules by running

    git submodule update --init
