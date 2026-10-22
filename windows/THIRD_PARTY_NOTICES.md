# Third-party software

Leeds HPC Monitor is MIT-licensed. The Windows distribution also includes:

- Python — PSF License: https://docs.python.org/3/license.html
- PySide6, Shiboken6 and Qt — LGPLv3/GPLv3/commercial licensing:
  https://doc.qt.io/qtforpython-6/licenses.html and https://www.qt.io/qt-licensing
  Source: https://download.qt.io/official_releases/QtForPython/pyside6/
  LGPLv3 text: https://www.gnu.org/licenses/lgpl-3.0.html
- Paramiko — LGPLv2.1: https://www.paramiko.org/licensing.html
- Cryptography — Apache-2.0 OR BSD-3-Clause: https://cryptography.io/en/latest/faq/#license
- PyNaCl — Apache-2.0: https://github.com/pyca/pynacl
- bcrypt — Apache-2.0: https://github.com/pyca/bcrypt
- keyring — MIT: https://github.com/jaraco/keyring
- tzdata (IANA time-zone database) — Apache-2.0: https://github.com/python/tzdata
- PyInstaller bootloader — GPL with an exception for bundled applications:
  https://pyinstaller.org/en/stable/license.html

The portable folder intentionally keeps Qt/Python shared libraries separate
under `_internal`, rather than statically linking them. Keep that folder with
the executable. You may replace LGPL-covered libraries with compatible modified
versions. This application does not prohibit reverse engineering for debugging
such modifications. Consult the linked projects for full licence terms and
corresponding source. The build script copies installed dependency licences
into `licenses/` alongside the executable.
