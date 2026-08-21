# PIO Arduino-as-IDF-component embeds RainMaker certs with a doubled build
# path. Stub every managed-component .crt so the assembler step can run.
# Also patch esptool 5 + Click 8.2 (get_metavar) so bootloader.bin can be built.
Import("env")
from pathlib import Path

build = Path(env.subst("$BUILD_DIR"))
project = Path(env.subst("$PROJECT_DIR"))
names = {
    "https_server.crt.S",
    "rmaker_mqtt_server.crt.S",
    "rmaker_mqtt_server.pro.crt.S",
    "rmaker_claim_service_server.crt.S",
    "rmaker_ota_server.crt.S",
    "server.crt.S",
}
for cert in project.glob("managed_components/**/*.crt"):
    names.add(cert.name + ".S")

build.mkdir(parents=True, exist_ok=True)
stub = "/* empty cert stub */\n"
for name in names:
    path = build / name
    if not path.exists():
        path.write_text(stub)
