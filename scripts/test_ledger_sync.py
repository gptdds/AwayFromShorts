import copy
import importlib.util
import pathlib
import unittest
import tempfile
import json
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('ledger', pathlib.Path(__file__).parents[1] / 'src' / 'sync_ledger.py')
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class LedgerSyncTest(unittest.TestCase):
    def test_first_contact_uses_phone_edits_and_archive(self):
        local = {'goals': [{'id': 'lg-g', '目标ID': 'g', '目标名称': '旧', '截止日': '2026-11-01', '障碍': '保留'}], 'logs': []}
        remote = {'goals': [{'id': 'g', 'name': '新', 'due': '2027-11-01', 'archived': True}], 'recs': []}
        result, cloud = sync.merge(local, remote)
        self.assertEqual(result['goals'][0]['截止日'], '2027-11-01')
        self.assertTrue(result['goals'][0]['已归档'])
        self.assertEqual(result['goals'][0]['障碍'], '保留')
        self.assertEqual(cloud, remote)

    def test_bootstrap_does_not_revive_deleted_imported_record(self):
        local = {'goals': [], 'logs': [{'id': 'lr-r1', '记录ID': 'r1'}, {'id': 'L123', '记录ID': 'pc-new'}]}
        result, cloud = sync.merge(local, {'goals': [], 'recs': []})
        self.assertEqual([r['id'] for r in cloud['recs']], ['pc-new'])

    def test_independent_field_changes_merge(self):
        b = [{'id': 'g', 'name': 'original', 'due': '2026-11-01'}]
        l, r = copy.deepcopy(b), copy.deepcopy(b)
        l[0]['name'] = 'pc edit'
        r[0]['due'] = '2027-11-01'
        self.assertEqual(sync.merge_rows(l, r, b), [{'id': 'g', 'name': 'pc edit', 'due': '2027-11-01'}])

    def test_deletion_propagates_both_ways(self):
        b = [{'id': 'r', 'amount': 1}]
        self.assertEqual(sync.merge_rows([], b, b), [])
        self.assertEqual(sync.merge_rows(b, [], b), [])

    def test_both_devices_new_checkins_survive_and_deduplicate(self):
        l = [{'id': 'a'}, {'id': 'pc'}]
        r = [{'id': 'a'}, {'id': 'phone'}]
        merged = sync.merge_rows(l, r, [{'id': 'a'}])
        self.assertEqual({x['id'] for x in merged}, {'a', 'pc', 'phone'})
        self.assertEqual(sync.merge_rows(merged, merged, merged), merged)

    def test_amount_can_decrease(self):
        self.assertEqual(sync.merge_rows([{'id': 'r', 'amount': 5}], [{'id': 'r', 'amount': 2}], [{'id': 'r', 'amount': 5}])[0]['amount'], 2)

    def test_local_metadata_retained_and_input_not_mutated(self):
        local = {'goals': [], 'logs': [{'id': 'L1', '记录ID': 'r', '目标ID': 'g', '分钟': 12}], 'notes': [{'id': 'n'}]}
        before = copy.deepcopy(local)
        result, _ = sync.merge(local, {'goals': [], 'recs': [{'id': 'r', 'goalId': 'g', 'amount': 2}]})
        self.assertEqual(local, before)
        self.assertEqual(result['logs'][0]['分钟'], 12)
        self.assertEqual(result['notes'], local['notes'])

    def test_missing_local_file_restores_instead_of_deleting_cloud(self):
        remote = {'goals': [{'id': 'g', 'name': 'keep'}], 'recs': []}
        with tempfile.TemporaryDirectory() as directory:
            store = pathlib.Path(directory) / 'study-db.json'
            state = pathlib.Path(directory) / 'ledger-sync-state.json'
            state.write_text(json.dumps(remote))
            with patch.object(sync, 'STORE', str(store)), patch.object(sync, 'STATE', str(state)), patch.object(sync, 'HERE', directory), patch.object(sync, 'request', return_value=remote) as request:
                self.assertTrue(sync.synchronize()['ok'])
                self.assertEqual(request.call_count, 1)
                self.assertEqual(json.loads(store.read_text(encoding='utf-8'))['goals'][0]['目标ID'], 'g')

    def test_corrupt_local_file_never_pushes_empty_data(self):
        remote = {'goals': [{'id': 'g'}], 'recs': []}
        with tempfile.TemporaryDirectory() as directory:
            store = pathlib.Path(directory) / 'study-db.json'
            store.write_text('{broken')
            with patch.object(sync, 'STORE', str(store)), patch.object(sync, 'STATE', str(store) + '.state'), patch.object(sync, 'request', return_value=remote) as request:
                with self.assertRaises(ValueError): sync.synchronize()
                self.assertEqual(request.call_count, 1)
                self.assertEqual(store.read_text(), '{broken')


if __name__ == '__main__':
    unittest.main()
