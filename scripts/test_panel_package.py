import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import package_contract
import package_plugin

NEW_MODULES={'panel_modes','panel_detection_profile','web_panel_zoom','web_panel_analysis','web_panel_components'}

class PanelPackageTest(unittest.TestCase):
    def test_new_modules_in_strict_inventory(self):
        self.assertTrue(NEW_MODULES <= set(package_contract.MODULES))

    def test_current_version_and_source_inventory(self):
        members=package_plugin.source_members()
        self.assertIn(b'0.4.31',members['_meta.lua'])
        for name in NEW_MODULES:
            self.assertIn('webdavmanga/'+name+'.lua',members)

    def test_missing_module_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory)/'webdavmanga.koplugin'
            shutil.copytree(package_plugin.PLUGIN,target)
            (target/'webdavmanga/web_panel_analysis.lua').unlink()
            with patch.object(package_plugin,'PLUGIN',target):
                with self.assertRaisesRegex(ValueError,'inventory differs'):
                    package_plugin.source_members()

    def test_extra_sensitive_file_is_rejected(self):
        with self.assertRaisesRegex(ValueError,'unexpected or sensitive'):
            package_contract.validate_content('credentials.lua',b'return {}')

if __name__=='__main__':unittest.main()
