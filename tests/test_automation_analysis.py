import unittest
from diagnostics.analyze_automation import summarize


def event(stage, elapsed, extra=""):
    return (f"2026-01-01 [INFO] [app] automation_stage | request_id=one source=audio_playback_intent "
            f"requested_route=usb elapsed_ms={elapsed} stage={stage} {extra}")


class AutomationAnalysisTests(unittest.TestCase):
    def testEngineDoesNotClaimSoundOrReceivedAudio(self):
        rows = summarize(event("action_entered", 0, "ui_appeared=false application_state=2") + "\n" +
                         event("audio_engine_started", 400) + "\n" +
                         event("action_returned", 500, "result=engine_started"))
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]["engine_started"])
        self.assertFalse(rows[0]["received_audio_rendered"])
        self.assertEqual(rows[0]["audible_sound"], "not_measured")
        self.assertEqual(rows[0]["entry_app_state"], "2")

    def testLateAudioEvidenceAndDuplicateEntriesPreserveEarliestStage(self):
        text = "\n".join([event("action_returned", 8000, "result=waiting"),
                          event("received_audio_rendered", 9200), event("received_audio_rendered", 10000)])
        row = summarize(text)[0]
        self.assertTrue(row["received_audio_rendered"])
        self.assertEqual(row["stages_ms"]["received_audio_rendered"], 9200)
        self.assertEqual(row["returned_result"], "waiting")

    def testAbsenceOfLogDoesNotInventTriggerFailure(self):
        self.assertEqual(summarize("unrelated events\nno automation recorded"), [])
