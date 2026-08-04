import io
import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2] / "Sources" / "ToolBoxOCRWorker"
sys.path.insert(0, str(ROOT))

from projections import polygon, sanitize_html, sanitize_markdown, structure_result, vl_result  # noqa: E402
import toolbox_ocr_worker as worker  # noqa: E402
from toolbox_ocr_worker import construct_pipeline, required_model_dir  # noqa: E402


class ProjectionTests(unittest.TestCase):
    def test_structure_fixture_preserves_layout_and_ocr_blocks(self):
        result = structure_result(
            [{
                "layout_det_res": {"boxes": [{"label": "title", "bbox": [10, 20, 90, 40]}]},
                "overall_ocr_res": {
                    "rec_texts": ["Report"],
                    "rec_polys": [[[10, 20], [90, 20], [90, 40], [10, 40]]],
                    "rec_scores": [0.98],
                },
                "table_res_list": [{"cell_box_list": [[10, 50, 90, 100]], "pred_html": "<table><tr><td>A</td></tr></table>"}],
                "formula_res_list": [{"rec_formula": "x^2", "dt_polys": [[10, 5, 40, 20]]}],
            }],
            100,
            100,
        )
        self.assertEqual([item["kind"] for item in result], ["title", "paragraph", "table", "formula"])
        self.assertEqual(result[0]["polygon"][0], [0.1, 0.2])
        self.assertEqual(result[2]["html"].startswith("<table>"), True)
        self.assertEqual(result[3]["text"], "x^2")

    def test_vl_fixture_returns_markdown_and_source_ranges(self):
        markdown, blocks = vl_result(
            [{
                "markdown": {"markdown_texts": "# Report\n\nBody"},
                "parsing_res_list": [{"label": "title", "text": "# Report", "bbox": [0, 0, 100, 20]}],
            }],
            100,
            100,
        )
        self.assertEqual(markdown, "# Report\n\nBody")
        self.assertEqual(blocks[0]["markdownStart"], 0)
        self.assertEqual(blocks[0]["markdownEnd"], 8)

    def test_vl_ranges_use_utf16_offsets(self):
        markdown, blocks = vl_result(
            [{
                "markdown": {"markdown_texts": "😀 Body"},
                "parsing_res_list": [{"label": "paragraph", "text": "Body", "bbox": [0, 0, 100, 20]}],
            }],
            100,
            100,
        )
        self.assertEqual(markdown, "😀 Body")
        self.assertEqual(blocks[0]["markdownStart"], 3)

    def test_malformed_geometry_is_bounded(self):
        self.assertEqual(len(polygon(None, 100, 100)), 4)
        self.assertEqual(sanitize_markdown("javascript:alert(1)"), "alert(1)")
        self.assertNotIn("script", sanitize_html("<script>alert(1)</script><table></table>"))


class WorkerContractTests(unittest.TestCase):
    def test_worker_module_does_not_require_paddle_until_inference(self):
        module_path = ROOT / "toolbox_ocr_worker.py"
        source = module_path.read_text(encoding="utf-8")
        self.assertNotIn("from paddleocr import", source.split("def construct_pipeline", 1)[0])

    def test_library_stdout_cannot_corrupt_jsonl_protocol(self):
        from PIL import Image

        class NoisyPipeline:
            def predict(self, _):
                print("paddlex diagnostic")
                return [{"layout_det_res": {"boxes": []}}]

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            Image.new("RGB", (2, 2)).save(root / "input.png")
            output = io.StringIO()
            request = {
                "schemaVersion": 1,
                "type": "request",
                "taskID": "protocol-check",
                "pipeline": "ppStructureV3",
                "variantID": "default",
                "modelDirectory": str(root),
                "imagePath": "input.png",
            }
            with (
                mock.patch.object(worker.Path, "cwd", return_value=root),
                mock.patch.object(worker, "construct_pipeline", return_value=NoisyPipeline()),
                mock.patch.object(worker.sys, "stdout", output),
                mock.patch.object(worker.sys, "stderr", io.StringIO()),
            ):
                worker.run_request(request, worker.threading.Event())

        messages = output.getvalue().splitlines()
        self.assertEqual(len(messages), 1)
        self.assertEqual(json.loads(messages[0])["type"], "result")

    def test_input_paths_are_private_to_the_session(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.png"
            path.write_bytes(b"fixture")
            self.assertTrue(path.is_file())

    def test_structure_pipeline_uses_distinct_verified_component_directories(self):
        captured = {}
        module = types.ModuleType("paddleocr")

        def structure(**kwargs):
            captured.update(kwargs)
            return object()

        module.PPStructureV3 = structure
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            components = (
                "layout", "region", "text_det", "text_rec", "table_cls",
                "table_wired", "table_wireless", "table_cell_wired",
                "table_cell_wireless", "table_orientation", "formula", "chart",
                "textline_orientation",
            )
            for component in components:
                (root / component).mkdir()
            previous = sys.modules.get("paddleocr")
            sys.modules["paddleocr"] = module
            try:
                construct_pipeline("ppStructureV3", "default", root)
            finally:
                if previous is None:
                    sys.modules.pop("paddleocr", None)
                else:
                    sys.modules["paddleocr"] = previous

        self.assertEqual(captured["layout_detection_model_dir"], str(root / "layout"))
        self.assertEqual(captured["text_detection_model_dir"], str(root / "text_det"))
        self.assertEqual(captured["text_recognition_model_dir"], str(root / "text_rec"))
        self.assertEqual(
            {
                key: captured[key]
                for key in (
                    "layout_detection_model_name",
                    "region_detection_model_name",
                    "table_classification_model_name",
                    "wired_table_structure_recognition_model_name",
                    "wireless_table_structure_recognition_model_name",
                    "wired_table_cells_detection_model_name",
                    "wireless_table_cells_detection_model_name",
                    "table_orientation_classify_model_name",
                    "textline_orientation_model_name",
                    "formula_recognition_model_name",
                )
            },
            {
                "layout_detection_model_name": "PP-DocLayout_plus-L",
                "region_detection_model_name": "PP-DocBlockLayout",
                "table_classification_model_name": "PP-LCNet_x1_0_table_cls",
                "wired_table_structure_recognition_model_name": "SLANeXt_wired",
                "wireless_table_structure_recognition_model_name": "SLANet_plus",
                "wired_table_cells_detection_model_name": "RT-DETR-L_wired_table_cell_det",
                "wireless_table_cells_detection_model_name": "RT-DETR-L_wireless_table_cell_det",
                "table_orientation_classify_model_name": "PP-LCNet_x1_0_doc_ori",
                "textline_orientation_model_name": "PP-LCNet_x1_0_textline_ori",
                "formula_recognition_model_name": "PP-FormulaNet_plus-L",
            },
        )
        self.assertNotEqual(
            captured["wired_table_structure_recognition_model_dir"],
            captured["wireless_table_structure_recognition_model_dir"],
        )

    def test_missing_component_does_not_fall_back_to_model_root(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(FileNotFoundError, "layout"):
                required_model_dir(Path(directory).resolve(), "layout")

    def test_vl_pipeline_defaults_to_local_native_backend(self):
        captured = {}
        module = types.ModuleType("paddleocr")

        def paddle_vl(**kwargs):
            captured.update(kwargs)
            return object()

        module.PaddleOCRVL = paddle_vl
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "vl").mkdir()
            (root / "layout").mkdir()
            previous = sys.modules.get("paddleocr")
            previous_backend = os.environ.pop("TOOLBOX_OCR_VL_BACKEND", None)
            sys.modules["paddleocr"] = module
            try:
                construct_pipeline("paddleOCRVL", "v1.6", root)
            finally:
                if previous_backend is not None:
                    os.environ["TOOLBOX_OCR_VL_BACKEND"] = previous_backend
                if previous is None:
                    sys.modules.pop("paddleocr", None)
                else:
                    sys.modules["paddleocr"] = previous

        self.assertEqual(captured["vl_rec_backend"], "native")
        self.assertEqual(captured["vl_rec_model_dir"], str(root / "vl"))
        self.assertEqual(captured["layout_detection_model_dir"], str(root / "layout"))
        self.assertEqual(captured["layout_detection_model_name"], "PP-DocLayoutV3")
        self.assertEqual(captured["vl_rec_model_name"], "PaddleOCR-VL-1.6-0.9B")


if __name__ == "__main__":
    unittest.main()
