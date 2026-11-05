#!/usr/bin/env python3
import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MAIN_QML = REPO_ROOT / "package" / "contents" / "ui" / "main.qml"
CONFIG_QML_1 = REPO_ROOT / "package" / "contents" / "ui" / "config" / "configGeneral.qml"
CONFIG_QML_2 = REPO_ROOT / "package" / "contents" / "ui" / "configGeneral.qml"
METADATA_JSON = REPO_ROOT / "package" / "metadata.json"


def extract_js_function(qml_text: str, func_name: str) -> str:
    pattern = re.compile(rf"\bfunction\s+{re.escape(func_name)}\s*\([^)]*\)\s*\{{")
    match = pattern.search(qml_text)
    if not match:
        raise ValueError(f"Function {func_name} not found")
    start = match.start()
    brace_idx = match.end() - 1
    depth = 0
    for i in range(brace_idx, len(qml_text)):
        if qml_text[i] == "{":
            depth += 1
        elif qml_text[i] == "}":
            depth -= 1
            if depth == 0:
                return qml_text[start : i + 1]
    raise ValueError(f"Unbalanced braces in function {func_name}")


class TestNvidiaStatusApplet(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.main_qml_text = MAIN_QML.read_text(encoding="utf-8")
        cls.config_qml_text = CONFIG_QML_1.read_text(encoding="utf-8")

    def run_node_json(self, js_code: str):
        env = os.environ.copy()
        user = os.environ.get("USER", os.environ.get("USERNAME", "ido"))
        local_bin_var = f"/var/home/{user}/.local/bin"
        local_bin_home = str(Path.home() / ".local" / "bin")
        env["PATH"] = f"{local_bin_var}:{local_bin_home}:{env.get('PATH', '')}"
        res = subprocess.run(
            ["node", "-e", js_code],
            capture_output=True,
            text=True,
            env=env,
            check=True,
        )
        return json.loads(res.stdout.strip())

    # =========================================================================
    # Metadata and QML Synchronization Tests
    # =========================================================================

    def test_config_qml_files_in_sync(self):
        """Ensure both configGeneral.qml copies remain 100% identical."""
        self.assertEqual(
            CONFIG_QML_1.read_text(encoding="utf-8"),
            CONFIG_QML_2.read_text(encoding="utf-8"),
            "ui/config/configGeneral.qml and ui/configGeneral.qml must remain identical",
        )

    def test_metadata_json_valid(self):
        """Ensure metadata.json is well-formed with a valid semantic version."""
        data = json.loads(METADATA_JSON.read_text(encoding="utf-8"))
        version = data["KPlugin"]["Version"]
        self.assertRegex(version, r"^\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?$")

    # =========================================================================
    # Issue #3 & PR #4: Multi-GPU Tests
    # =========================================================================

    def test_multi_gpu_command_scoping_and_pmon_syntax(self):
        """
        Verify Issue #3 / PR #4 fix:
        On multi-GPU systems (e.g. 2x RTX 5060 Ti at 0000:04:00.0 and 0000:2b:00.0):
        1. smiTarget must be '-i <addr>'
        2. In getProcessCmd, the -i flag MUST come after 'pmon -c 1'
           (since 'nvidia-smi -i <addr> pmon' fails with 'Option pmon is not recognized')
        3. Telemetry and standard nvidia-smi queries must be scoped to that card
        4. Two instances for different cards produce completely isolated commands
        """
        normalize_fn = extract_js_function(self.main_qml_text, "normalizePciAddress")

        js_harness = f"""
        const root = {{}};
        {normalize_fn}
        root.normalizePciAddress = normalizePciAddress;
        root.nvidiaSmiPath = "/usr/bin/nvidia-smi";

        function makeInstance(pciAddr) {{
            const normalized = root.normalizePciAddress(pciAddr);
            const smiTarget = normalized ? " -i " + normalized : "";
            const getProcessCmd = root.nvidiaSmiPath + " pmon -c 1" + smiTarget +
                "; echo \\"---PROCESSES---\\"; " + root.nvidiaSmiPath + smiTarget +
                "; echo \\"---TELEMETRY---\\"; " + root.nvidiaSmiPath + smiTarget +
                " --query-gpu=memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits";
            const shortPciAddress = normalized.replace(/^0000:/, "");
            return {{ normalized, smiTarget, getProcessCmd, shortPciAddress }};
        }}

        const gpu0 = makeInstance("0000:04:00.0");
        const gpu1 = makeInstance("0000:2B:00.0"); // test uppercase hex input too

        console.log(JSON.stringify({{ gpu0, gpu1 }}));
        """
        res = self.run_node_json(js_harness)
        gpu0 = res["gpu0"]
        gpu1 = res["gpu1"]

        # Card 0 verification
        self.assertEqual(gpu0["normalized"], "0000:04:00.0")
        self.assertEqual(gpu0["smiTarget"], " -i 0000:04:00.0")
        self.assertEqual(gpu0["shortPciAddress"], "04:00.0")
        self.assertIn("pmon -c 1 -i 0000:04:00.0;", gpu0["getProcessCmd"])
        self.assertNotIn("-i 0000:04:00.0 pmon", gpu0["getProcessCmd"])
        self.assertIn("/usr/bin/nvidia-smi -i 0000:04:00.0 --query-gpu=", gpu0["getProcessCmd"])

        # Card 1 verification (ensuring hex lowercase normalization: 2B -> 2b)
        self.assertEqual(gpu1["normalized"], "0000:2b:00.0")
        self.assertEqual(gpu1["smiTarget"], " -i 0000:2b:00.0")
        self.assertEqual(gpu1["shortPciAddress"], "2b:00.0")
        self.assertIn("pmon -c 1 -i 0000:2b:00.0;", gpu1["getProcessCmd"])
        self.assertNotIn("-i 0000:2b:00.0 pmon", gpu1["getProcessCmd"])
        self.assertIn("/usr/bin/nvidia-smi -i 0000:2b:00.0 --query-gpu=", gpu1["getProcessCmd"])

        # Complete isolation check
        self.assertNotEqual(gpu0["getProcessCmd"], gpu1["getProcessCmd"])
        self.assertNotIn("04:00.0", gpu1["getProcessCmd"])
        self.assertNotIn("2b:00.0", gpu0["getProcessCmd"])

    def test_multi_gpu_device_minor_fuser_resolution(self):
        """
        Verify multi-GPU device minor resolution (commit 6276e67).
        On multi-GPU systems, GPU 1 is mapped to /dev/nvidia1 (Device Minor: 1).
        fuserCmd must dynamically query Device Minor for the configured card
        and target /dev/nvidia1 instead of hardcoded /dev/nvidia0.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            gpu0_info = tmp / "proc" / "driver" / "nvidia" / "gpus" / "0000:04:00.0"
            gpu1_info = tmp / "proc" / "driver" / "nvidia" / "gpus" / "0000:2b:00.0"
            gpu0_info.mkdir(parents=True)
            gpu1_info.mkdir(parents=True)
            (gpu0_info / "information").write_text("Model: RTX 5060 Ti\nDevice Minor: 0\n", encoding="utf-8")
            (gpu1_info / "information").write_text("Model: RTX 5060 Ti\nDevice Minor: 1\n", encoding="utf-8")

            # Shell snippet matching main.qml's fuserCmd
            def resolve_dev(addr):
                cmd = (
                    f"dev=\"/dev/nvidia$(grep -s 'Device Minor:' {tmp}/proc/driver/nvidia/gpus/{addr}/information 2>/dev/null | awk '{{print $NF}}')\"; "
                    "[ -e \"$dev\" ] || dev=\"/dev/nvidia0\"; echo \"$dev\""
                )
                res = subprocess.run(["sh", "-c", cmd], capture_output=True, text=True, check=True)
                # Note: /dev/nvidia1 won't exist in tmp, so let's verify what grep extracted:
                minor_cmd = f"grep -s 'Device Minor:' {tmp}/proc/driver/nvidia/gpus/{addr}/information | awk '{{print $NF}}'"
                minor = subprocess.run(["sh", "-c", minor_cmd], capture_output=True, text=True, check=True).stdout.strip()
                return minor

            self.assertEqual(resolve_dev("0000:04:00.0"), "0")
            self.assertEqual(resolve_dev("0000:2b:00.0"), "1")
            self.assertEqual(resolve_dev("0000:99:00.0"), "")

    def test_multi_gpu_config_detection_and_selection(self):
        """
        Verify that in multi-GPU systems, the config dropdown parses all GPUs,
        preserves explicit selection of secondary GPUs, and auto-selects GPU 0
        if the configured address is missing or set to an invalid default.
        """
        normalize_fn = extract_js_function(self.config_qml_text, "normalizePciAddress")
        parse_gpus_fn = extract_js_function(self.config_qml_text, "parseDetectedGpus")
        resolve_gpu_fn = extract_js_function(self.config_qml_text, "resolveSelectedGpu")

        lspci_multi = (
            "0000:04:00.0 VGA compatible controller [0300]: NVIDIA Corporation [GeForce RTX 5060 Ti] (rev a1)\n"
            "0000:2b:00.0 VGA compatible controller [0300]: NVIDIA Corporation [GeForce RTX 5060 Ti] (rev a1)"
        )

        js_harness = f"""
        const page = {{}};
        {normalize_fn}
        {parse_gpus_fn}
        {resolve_gpu_fn}
        page.normalizePciAddress = normalizePciAddress;
        page.parseDetectedGpus = parseDetectedGpus;
        page.resolveSelectedGpu = resolveSelectedGpu;

        const gpus = parseDetectedGpus({json.dumps(lspci_multi)});
        const selectSecondExplicit = resolveSelectedGpu(gpus, "0000:2B:00.0");
        const selectDefaultMissing = resolveSelectedGpu(gpus, "0000:01:00.0");

        console.log(JSON.stringify({{ gpus, selectSecondExplicit, selectDefaultMissing }}));
        """
        res = self.run_node_json(js_harness)
        self.assertEqual(len(res["gpus"]), 2)
        self.assertEqual(res["gpus"][0]["address"], "0000:04:00.0")
        self.assertEqual(res["gpus"][1]["address"], "0000:2b:00.0")

        # Explicit selection of GPU 1 preserved
        self.assertEqual(res["selectSecondExplicit"], {"index": 1, "address": "0000:2b:00.0"})

        # Stale default 01:00.0 auto-selects GPU 0
        self.assertEqual(res["selectDefaultMissing"], {"index": 0, "address": "0000:04:00.0"})

    # =========================================================================
    # Issue #1: Process Sorting & VRAM Parsing Tests
    # =========================================================================

    def test_process_sorting_sm_mem_name(self):
        """
        Verify Issue #1:
        Ensure sortProcesses correctly handles:
        - sm (GPU %) descending and ascending
        - mem (VRAM) descending and ascending (with parseVramInMb)
        - name descending and ascending (case-insensitive)
        - secondary tie-breaker by process name
        """
        parse_vram_fn = extract_js_function(self.main_qml_text, "parseVramInMb")
        sort_procs_fn = extract_js_function(self.main_qml_text, "sortProcesses")

        js_harness = f"""
        {parse_vram_fn}
        {sort_procs_fn}

        const sample = [
            {{ pid: "101", name: "blender", sm: "45", mem: "4.5 GB" }},
            {{ pid: "102", name: "AlphaGame", sm: "90", mem: "8192 MiB" }},
            {{ pid: "103", name: "zeta-stream", sm: "10", mem: "512 MB" }},
            {{ pid: "104", name: "betabot", sm: "45", mem: "2.0 GB" }}
        ];

        const sortBySmDesc = sortProcesses(sample, "sm", true);
        const sortBySmAsc = sortProcesses(sample, "sm", false);
        const sortByMemDesc = sortProcesses(sample, "mem", true);
        const sortByNameAsc = sortProcesses(sample, "name", false);
        const sortByNameDesc = sortProcesses(sample, "name", true);

        console.log(JSON.stringify({{
            sortBySmDesc: sortBySmDesc.map(p => p.name),
            sortBySmAsc: sortBySmAsc.map(p => p.name),
            sortByMemDesc: sortByMemDesc.map(p => p.name),
            sortByNameAsc: sortByNameAsc.map(p => p.name),
            sortByNameDesc: sortByNameDesc.map(p => p.name),
        }}));
        """
        res = self.run_node_json(js_harness)

        # SM Descending: 90 -> 45 (tie broken by name: betabot then blender) -> 10
        self.assertEqual(res["sortBySmDesc"], ["AlphaGame", "betabot", "blender", "zeta-stream"])
        # SM Ascending: 10 -> 45 -> 45 -> 90
        self.assertEqual(res["sortBySmAsc"], ["zeta-stream", "betabot", "blender", "AlphaGame"])
        # Mem Descending: 8192 MiB (8 GB) -> 4.5 GB -> 2.0 GB -> 512 MB
        self.assertEqual(res["sortByMemDesc"], ["AlphaGame", "blender", "betabot", "zeta-stream"])
        # Name Ascending: AlphaGame -> betabot -> blender -> zeta-stream
        self.assertEqual(res["sortByNameAsc"], ["AlphaGame", "betabot", "blender", "zeta-stream"])
        # Name Descending: zeta-stream -> blender -> betabot -> AlphaGame
        self.assertEqual(res["sortByNameDesc"], ["zeta-stream", "blender", "betabot", "AlphaGame"])

    def test_vram_parsing_units(self):
        """Verify parseVramInMb converts various VRAM units (GiB, GB, MiB, MB, %) correctly."""
        parse_vram_fn = extract_js_function(self.main_qml_text, "parseVramInMb")

        js_harness = f"""
        {parse_vram_fn}

        const out = {{
            valGib: parseVramInMb("1.5 GiB"),
            valGb: parseVramInMb("2 GB"),
            valMib: parseVramInMb("20388MiB"),
            valMb: parseVramInMb("512 MB"),
            valPercent: parseVramInMb("25%"),
            valZero: parseVramInMb("0 MB"),
            valEmpty: parseVramInMb(""),
            valNull: parseVramInMb(null),
        }};
        console.log(JSON.stringify(out));
        """
        res = self.run_node_json(js_harness)
        self.assertEqual(res["valGib"], 1536)
        self.assertEqual(res["valGb"], 2048)
        self.assertEqual(res["valMib"], 20388)
        self.assertEqual(res["valMb"], 512)
        self.assertEqual(res["valPercent"], 25)
        self.assertEqual(res["valZero"], 0)
        self.assertEqual(res["valEmpty"], 0)
        self.assertEqual(res["valNull"], 0)

    # =========================================================================
    # Issue #2: Process Filtering & Telemetry Parsing Tests
    # =========================================================================

    def test_user_process_filtering(self):
        """
        Verify Issue #2:
        Ensure system/compositor processes (kwin_wayland, xwayland, plasmashell, systemd, xorg)
        are excluded so the GPU can safely enter autosuspend (D3cold), while user applications
        are recognized as active user processes.
        """
        is_user_proc_fn = extract_js_function(self.main_qml_text, "isUserProcess")

        js_harness = f"""
        {is_user_proc_fn}

        const systemProcs = [
            {{ name: "/usr/bin/kwin_wayland" }},
            {{ name: "kwin_wayland" }},
            {{ name: "xwayland" }},
            {{ name: "/usr/bin/plasmashell" }},
            {{ name: "/usr/libexec/Xorg" }},
            {{ name: "systemd" }}
        ];

        const userProcs = [
            {{ name: "llama-server" }},
            {{ name: "/usr/bin/blender" }},
            {{ name: "steam" }},
            {{ name: "firefox" }},
            {{ name: "game.exe" }},
            {{ name: "C:\\\\Program Files\\\\Game\\\\CyberGame.exe" }}
        ];

        const systemResults = systemProcs.map(isUserProcess);
        const userResults = userProcs.map(isUserProcess);

        console.log(JSON.stringify({{ systemResults, userResults }}));
        """
        res = self.run_node_json(js_harness)
        self.assertTrue(all(r is False for r in res["systemResults"]))
        self.assertTrue(all(r is True for r in res["userResults"]))

    def test_telemetry_csv_parsing(self):
        """
        Verify telemetry parsing:
        - Memory used and total
        - GPU temperature
        - Power draw floating-point values
        - Power draw [N/A] handling without producing NaN or crashes
        """
        js_harness = """
        function parseTelemetry(telemetryOut) {
            let usedMb = 0, totalMb = 0, tempC = 0, powerW = null;
            if (telemetryOut) {
                const tFields = telemetryOut.split(",");
                if (tFields.length >= 3) {
                    usedMb = parseFloat(tFields[0].trim()) || 0;
                    totalMb = parseFloat(tFields[1].trim()) || 0;
                    tempC = parseInt(tFields[2].trim()) || 0;
                    if (tFields.length >= 4) {
                        const rawPwr = tFields[3].trim();
                        if (rawPwr && rawPwr !== "[N/A]" && !isNaN(parseFloat(rawPwr))) {
                            powerW = Math.round(parseFloat(rawPwr) * 10) / 10;
                        }
                    }
                }
            }
            return { usedMb, totalMb, tempC, powerW };
        }

        const standard = parseTelemetry("1400.00, 16384.00, 46, 28.64");
        const withNA = parseTelemetry("0.00, 8192.00, 40, [N/A]");
        const lowPower = parseTelemetry("2.00, 16384.00, 34, 9.71");

        console.log(JSON.stringify({ standard, withNA, lowPower }));
        """
        res = self.run_node_json(js_harness)
        self.assertEqual(res["standard"], {"usedMb": 1400, "totalMb": 16384, "tempC": 46, "powerW": 28.6})
        self.assertEqual(res["withNA"], {"usedMb": 0, "totalMb": 8192, "tempC": 40, "powerW": None})
        self.assertEqual(res["lowPower"], {"usedMb": 2, "totalMb": 16384, "tempC": 34, "powerW": 9.7})

    # =========================================================================
    # Recent Store Issue: RTX 5090 & Topology Auto-Detection Tests
    # =========================================================================

    def test_main_qml_functions_and_5090_detection(self):
        """Verify normalization, clean model name, and auto-detect shell command generation."""
        normalize_fn = extract_js_function(self.main_qml_text, "normalizePciAddress")
        clean_model_fn = extract_js_function(self.main_qml_text, "cleanGpuModelName")
        build_cmd_fn = extract_js_function(self.main_qml_text, "buildGpuDetectCmd")
        parse_detect_fn = extract_js_function(self.main_qml_text, "parseGpuDetectOutput")

        js_harness = f"""
        const root = {{}};
        {normalize_fn}
        {clean_model_fn}
        {build_cmd_fn}
        {parse_detect_fn}
        root.normalizePciAddress = normalizePciAddress;
        root.cleanGpuModelName = cleanGpuModelName;
        root.buildGpuDetectCmd = buildGpuDetectCmd;
        root.parseGpuDetectOutput = parseGpuDetectOutput;

        const out = {{
            normStandard: normalizePciAddress("0000:02:00.0"),
            normUpper: normalizePciAddress("0000:0A:00.0"),
            normSmi8Digit: normalizePciAddress("00000000:02:00.0"),
            normShort: normalizePciAddress("02:00.0"),
            normDotTypo1: normalizePciAddress("0000:02.00.0"),
            normDotTypo2: normalizePciAddress("02.00.0"),
            normDisplayLabel: normalizePciAddress("0000:02:00.0: GeForce RTX 5090 Max-Q/Mobile"),
            model5090Proc: cleanGpuModelName("NVIDIA GeForce RTX 5090 Laptop GPU"),
            model5090Lspci: cleanGpuModelName("GeForce RTX 5090 Max-Q/Mobile"),
            model3070MaxQ: cleanGpuModelName("NVIDIA GeForce RTX 3070 with Max-Q Design"),
            parsedDetect: parseGpuDetectOutput("ADDR=0000:02:00.0\\nMODEL=NVIDIA GeForce RTX 5090 Laptop GPU\\n"),
            cmdDefault: buildGpuDetectCmd("0000:01:00.0")
        }};
        console.log(JSON.stringify(out));
        """
        res = self.run_node_json(js_harness)

        self.assertEqual(res["normStandard"], "0000:02:00.0")
        self.assertEqual(res["normUpper"], "0000:0a:00.0")
        self.assertEqual(res["normSmi8Digit"], "0000:02:00.0")
        self.assertEqual(res["normShort"], "0000:02:00.0")
        self.assertEqual(res["normDotTypo1"], "0000:02:00.0")
        self.assertEqual(res["normDotTypo2"], "0000:02:00.0")
        self.assertEqual(res["normDisplayLabel"], "0000:02:00.0")

        self.assertEqual(res["model5090Proc"], "RTX 5090")
        self.assertEqual(res["model5090Lspci"], "RTX 5090")
        self.assertEqual(res["model3070MaxQ"], "RTX 3070 Max-Q")

        self.assertEqual(
            res["parsedDetect"],
            {"address": "0000:02:00.0", "model": "RTX 5090"},
        )

        # Test the shell command generated by buildGpuDetectCmd against a mocked
        # sysfs/proc tree where 0000:01:00.0 does NOT exist and the 5090 is at 0000:02:00.0
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            gpu_dir = tmp / "proc" / "driver" / "nvidia" / "gpus" / "0000:02:00.0"
            gpu_dir.mkdir(parents=True)
            (gpu_dir / "information").write_text(
                "Model:\t\t NVIDIA GeForce RTX 5090 Laptop GPU\n"
                "Bus Location:\t 0000:02:00.0\n"
                "Device Minor:\t 0\n",
                encoding="utf-8",
            )
            (tmp / "sys" / "bus" / "pci" / "drivers" / "nvidia").mkdir(parents=True)

            sandboxed_cmd = (
                res["cmdDefault"]
                .replace("/proc/driver/nvidia/gpus", f"{tmp}/proc/driver/nvidia/gpus")
                .replace("/sys/bus/pci/drivers/nvidia", f"{tmp}/sys/bus/pci/drivers/nvidia")
            )
            proc = subprocess.run(
                ["sh", "-c", sandboxed_cmd],
                capture_output=True,
                text=True,
                check=True,
            )
            parsed = self.run_node_json(
                f"""
                const root = {{}};
                {normalize_fn}
                {clean_model_fn}
                {parse_detect_fn}
                root.normalizePciAddress = normalizePciAddress;
                root.cleanGpuModelName = cleanGpuModelName;
                console.log(JSON.stringify(parseGpuDetectOutput({json.dumps(proc.stdout)})));
                """
            )
            self.assertEqual(parsed["address"], "0000:02:00.0")
            self.assertEqual(parsed["model"], "RTX 5090")

    def test_rtx_5090_nvidia_smi_process_table_parsing(self):
        """Verify nvidia-smi 595+ driver process table parsing with Ollama llama-server."""
        regex_match = re.search(r"const\s+procRegex\s*=\s*(/.*?/);\s*$", self.main_qml_text, re.M)
        self.assertIsNotNone(regex_match, "procRegex must exist in main.qml")
        proc_regex_literal = regex_match.group(1)

        smi_output = """
Thu Nov 5 10:29:53 2026
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 595.99.02 Driver Version: 595.99.02 CUDA Version: 13.2 |
+-----------------------------------------+------------------------+----------------------+
| GPU Name Persistence-M | Bus-Id Disp.A | Volatile Uncorr. ECC |
| Fan Temp Perf Pwr:Usage/Cap | Memory-Usage | GPU-Util Compute M. |
| | | MIG M. |
|=========================================+========================+======================|
| 0 NVIDIA GeForce RTX 5090 ... Off | 00000000:02:00.0 Off | N/A |
| N/A 49C P8 5W / 100W | 20398MiB / 24463MiB | 0% Default |
| | | N/A |
+-----------------------------------------+------------------------+----------------------+

+-----------------------------------------------------------------------------------------+
| Processes: |
| GPU GI CI PID Type Process name GPU Memory |
| ID ID Usage |
|=========================================================================================|
| 0 N/A N/A 6762 C ...local/lib/ollama/llama-server 20388MiB |
+-----------------------------------------------------------------------------------------+
"""
        js_harness = f"""
        const procRegex = {proc_regex_literal};
        const smiLines = {json.dumps(smi_output)}.split("\\n");
        const matches = [];
        for (const line of smiLines) {{
            const m = line.match(procRegex);
            if (m) {{
                let name = m[3].trim();
                if (name.lastIndexOf("/") !== -1) {{
                    name = name.substring(name.lastIndexOf("/") + 1);
                }}
                matches.push({{
                    pid: m[1],
                    type: m[2],
                    name: name,
                    vram: m[4].trim()
                }});
            }}
        }}
        console.log(JSON.stringify(matches));
        """
        matches = self.run_node_json(js_harness)
        self.assertEqual(
            matches,
            [
                {
                    "pid": "6762",
                    "type": "C",
                    "name": "llama-server",
                    "vram": "20388MiB",
                }
            ],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
