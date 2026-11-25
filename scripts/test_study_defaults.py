import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('study', pathlib.Path(__file__).parents[1] / 'src' / 'check_study.py')
study = importlib.util.module_from_spec(spec)
spec.loader.exec_module(study)


class StudyDefaultsTest(unittest.TestCase):
    def test_undated_goals_use_30_day_plan(self):
        self.assertEqual(study.suggest_amount(90, study.days_left('', '2026-10-24')), 3)

    def test_local_daily_amount_reaches_gate_snapshot(self):
        with tempfile.TemporaryDirectory() as folder:
            store = {'goals': [{'目标ID': 'g', '目标名称': 'Test', '总量': 100,
                                '每日默认量': 7, '截止日': ''}], 'logs': []}
            pathlib.Path(folder, 'study-db.json').write_text(json.dumps(store), encoding='utf-8')
            with patch.object(study, 'HERE', folder), patch.object(study, 'FLAG', str(pathlib.Path(folder, 'study.flag'))), patch.object(study, 'fetch_ledger', return_value=None):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    study.main()
                result = json.loads(out.getvalue())
                self.assertEqual(result['goals'][0]['suggest'], 7)
                self.assertEqual(result['pending'], 1)
                self.assertEqual(store['logs'], [])


if __name__ == '__main__':
    unittest.main()
