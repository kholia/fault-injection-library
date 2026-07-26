#!/usr/bin/env python3
# Copyright (C) 2024 Dr. Matthias Kesenheimer - All Rights Reserved.
# You may use, distribute and modify this code under the terms of the GPL3 license.
#
# You should have received a copy of the GPL3 license with this file.
# If not, please write to: info@faultyhardware.de.

import argparse
import json
import os
import sys
import tempfile
import findus
from findus.helper import upload

def files_for_version(version: str) -> list[str]:
    """
    """
    files = ["AD910X.py", "FastADC.py", "Globals.py", "PicoGlitcher.py", "PulseGenerator.py", "Spline.py", "Statemachines.py"]
    if version == 'v0':
        files.append("config_v0/config.json")
    elif version == 'v1':
        files.append("config_v1/config.json")
    elif version == 'v2.1' or version == 'v2.2':
        files.append("config_v2.1-2/config.json")
    elif version == 'v2.3' or version == 'v2.4':
        files.append("config_v2.3-4/config.json")
    elif version == 'v2.5' or version == 'v3.0':
        files.append("config_v3.0/config.json")
    else:
        print(f"[-] Version string {version} not allowed. Choose either v0, v1, v2.1, v2.2, v2.3, v2.4, v2.5 or v3.0.")
        sys.exit(-1)
    module_path = os.path.dirname(os.path.abspath(findus.__file__))
    firmware_path = os.path.join(module_path, "firmware")
    print(f"[+] Using base path {firmware_path}")
    files_with_path = [os.path.join(firmware_path, f) for f in files]
    return files_with_path

def main(argv=sys.argv):
    parser = argparse.ArgumentParser(
        description="Update the firmware of the SimpleGlitcher or Pico Glitcher."
    )
    parser.add_argument("--port", help="/dev/tty* of the Raspberry Pi Pico", required=True, default='/dev/ttyACM1')
    parser.add_argument("--version", help="Glitcher hardware (one of v0, v1, v2.1, v2.2, v2.3, v2.4, v2.5, v3.0)", required=False, default='v3.0')
    parser.add_argument("--vtarget-switch", choices=["TPS2041B", "TPS2051B"], help="SimpleGlitcher v0 VTARGET switch (default: TPS2051B)", required=False)
    args = parser.parse_args(argv[1:])

    # get the file list
    files = files_for_version(args.version)

    if args.vtarget_switch is not None and args.version != "v0":
        parser.error("--vtarget-switch is only valid with --version v0")

    with tempfile.TemporaryDirectory(prefix="findus-update-") as temp_dir:
        if args.version == "v0" and args.vtarget_switch is not None:
            with open(files[-1], "r") as file:
                config = json.load(file)
            config["vtarget_switch"] = args.vtarget_switch
            config_path = os.path.join(temp_dir, "config.json")
            with open(config_path, "w") as file:
                json.dump(config, file)
            files[-1] = config_path

        # reset before tasks to have a well defined state
        upload.reset(args.port)

        pyb = upload.connect(args.port)
        remote_files = upload.list_remote_files(pyb)

        print("[+] Deleting all files...")
        upload.delete_files(pyb, remote_files)

        pyb.exit_raw_repl()
        pyb.close()

        upload.upload_files_batch(files, args.port)
        upload.reset(args.port)

        # what is on the Raspberry Pi Pico?
        upload.print_remote_content(args.port)

if __name__ == "__main__":
    main()
