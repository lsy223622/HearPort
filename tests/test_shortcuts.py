import plistlib
import tempfile
import unittest
from pathlib import Path
from scripts.build_shortcuts import URL_COMMANDS, build


class ShortcutPackageTests(unittest.TestCase):
    def testEveryExportContainsOnlyItsFixedLocalCommand(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            results = build(root)
            self.assertEqual(len(results), 5)
            for name, url in URL_COMMANDS.items():
                data = plistlib.loads((root / "sources" / (name + ".shortcut")).read_bytes())
                actions = data["WFWorkflowActions"]
                self.assertEqual(actions[0]["WFWorkflowActionParameters"]["WFURLActionURL"], url)
                self.assertEqual(actions[1]["WFWorkflowActionIdentifier"], "is.workflow.actions.openurl")
                self.assertNotIn("host=", url)
                self.assertNotIn("pin=", url)
            self.assertFalse(any(item["signed"] for item in results))
