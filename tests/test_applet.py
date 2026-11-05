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
        local_bin = Path.home() / ".local" / "bin"
        env["PATH"] = f"{local_bin}:{env.get('PATH', '')}"
        res = subprocess.run(
            ["node", "-e", js_code],
            capture_output=True,
            text=True,
            env=env,
            check=True,
        )
        return json.loads(res.stdout.strip())

    def test_config_qml_files_in_sync(self):
        self.assertEqual(
            CONFIG_QML_1.read_text(encoding="utf-8"),
            CONFIG_QML_2.read_text(encoding="utf-8"),
            "ui/config/configGeneral.qml and ui/configGeneral.qml must remain identical",
        )

    def test_metadata_json_valid(self):
        data = json.loads(METADATA_JSON.read_text(encoding="utf-8"))
        version = data["KPlugin"]["Version"]
        self.assertRegex(version, r"^\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?$")

    def test_main_qml_functions_and_5090_detection(self):
        normalize_fn = extract_js_function(self.main_qml_text, "normalizePciAddress")
        clean_model_fn = extract_js_function(self.main_qml_text, "cleanGpuModelName")
        build_cmd_fn = extract_js_function(self.main_qml_text, "buildGpuDetectCmd")
        parse_detect_fn = extract_js_function(self.main_qml_text, "parseGpuDetectOutput")
        is_user_proc_fn = extract_js_function(self.main_qml_text, "isUserProcess")

        js_harness = f"""
        const root = {{}};
        {normalize_fn}
        {clean_model_fn}
        {build_cmd_fn}
        {parse_detect_fn}
        {is_user_proc_fn}
        root.normalizePciAddress = normalizePciAddress;
        root.cleanGpuModelName = cleanGpuModelName;
        root.buildGpuDetectCmd = buildGpuDetectCmd;
        root.parseGpuDetectOutput = parseGpuDetectOutput;
        root.isUserProcess = isUserProcess;

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
            cmdDefault: buildGpuDetectCmd("0000:01:00.0"),
            userProcOllama: isUserProcess({{ name: "llama-server" }}),
            userProcKwin: isUserProcess({{ name: "/usr/bin/kwin_wayland" }}),
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
        self.assertTrue(res["userProcOllama"])
        self.assertFalse(res["userProcKwin"])

        # Now test the shell command generated by buildGpuDetectCmd against a mocked
        # filesystem where 0000:01:00.0 is NOT an NVIDIA GPU and the RTX 5090 is at 0000:02:00.0
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

    def test_config_general_auto_selects_detected_gpu(self):
        normalize_fn = extract_js_function(self.config_qml_text, "normalizePciAddress")
        parse_gpus_fn = extract_js_function(self.config_qml_text, "parseDetectedGpus")
        resolve_gpu_fn = extract_js_function(self.config_qml_text, "resolveSelectedGpu")

        lspci_5090 = (
            "0000:02:00.0 VGA compatible controller [0300]: "
            "NVIDIA Corporation [GeForce RTX 5090 Max-Q/Mobile] (rev a1)"
        )
        lspci_multi = (
            "0000:01:00.0 VGA compatible controller: NVIDIA Corporation [GeForce RTX 3070]\n"
            "0000:02:00.0 3D controller: NVIDIA Corporation [GeForce RTX 5090 Max-Q/Mobile]"
        )

        js_harness = f"""
        const page = {{}};
        {normalize_fn}
        {parse_gpus_fn}
        {resolve_gpu_fn}
        page.normalizePciAddress = normalizePciAddress;
        page.parseDetectedGpus = parseDetectedGpus;
        page.resolveSelectedGpu = resolveSelectedGpu;

        const singleList = parseDetectedGpus({json.dumps(lspci_5090)});
        const resolvedFromDefault = resolveSelectedGpu(singleList, "0000:01:00.0");
        const resolvedFromEmpty = resolveSelectedGpu(singleList, "");

        const multiList = parseDetectedGpus({json.dumps(lspci_multi)});
        const resolvedMultiSecond = resolveSelectedGpu(multiList, "0000:02:00.0");

        console.log(JSON.stringify({{
            singleList,
            resolvedFromDefault,
            resolvedFromEmpty,
            resolvedMultiSecond,
        }}));
        """
        res = self.run_node_json(js_harness)

        self.assertEqual(len(res["singleList"]), 1)
        self.assertEqual(res["singleList"][0]["address"], "0000:02:00.0")
        # Crucial fix: when config had default 0000:01:00.0 but system only has 0000:02:00.0,
        # configGeneral auto-selects index 0 and updates the PCI address field to 0000:02:00.0
        self.assertEqual(
            res["resolvedFromDefault"],
            {"index": 0, "address": "0000:02:00.0"},
        )
        self.assertEqual(
            res["resolvedFromEmpty"],
            {"index": 0, "address": "0000:02:00.0"},
        )
        self.assertEqual(
            res["resolvedMultiSecond"],
            {"index": 1, "address": "0000:02:00.0"},
        )

    def test_rtx_5090_nvidia_smi_process_table_parsing(self):
        # Extract the exact procRegex from main.qml
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
