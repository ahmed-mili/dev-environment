import sys, tempfile, time, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import x_cookies as xc

def ck(name, domain=".x.com", **kw):
    return {"name": name, "value": "v-" + name, "domain": domain, "path": "/", **kw}

class FilterTests(unittest.TestCase):
    def test_keeps_only_x_domains(self):
        got = xc.filter_x([ck("a", ".x.com"), ck("b", "x.com"), ck("c", "api.x.com"),
                           ck("d", ".netflix.com"), ck("e", "twitter.com")])
        self.assertEqual([c["name"] for c in got], ["a", "b", "c"])

    def test_normalizes_samesite_and_expiry(self):
        c = xc.filter_x([ck("a", sameSite="no_restriction", expires=-1)])[0]
        self.assertEqual(c["sameSite"], "Lax")
        self.assertNotIn("expires", c)
        c = xc.filter_x([ck("a", sameSite="None", expires=1.9e9, httpOnly=1)])[0]
        self.assertEqual((c["sameSite"], c["expires"], c["httpOnly"]), ("None", 1.9e9, True))

    def test_missing_required(self):
        self.assertEqual(xc.missing_required([ck("ct0")]), ["auth_token"])

class StoreTests(unittest.TestCase):
    def setUp(self):
        self.path = Path(tempfile.mkdtemp()) / "sub" / "x-cookies.json"

    def test_roundtrip(self):
        cookies = xc.filter_x([ck("auth_token", expires=time.time() + 3600), ck("ct0")])
        xc.save_cookies(cookies, self.path)
        self.assertEqual(xc.load_cookies(self.path), cookies)

    def test_absent_malformed_incomplete_expired(self):
        self.assertIsNone(xc.load_cookies(self.path))
        self.path.parent.mkdir(parents=True)
        self.path.write_text("{pas du json", encoding="utf-8")
        self.assertIsNone(xc.load_cookies(self.path))
        xc.save_cookies(xc.filter_x([ck("ct0")]), self.path)
        self.assertIsNone(xc.load_cookies(self.path))
        xc.save_cookies(xc.filter_x([ck("auth_token", expires=1000), ck("ct0")]), self.path)
        self.assertIsNone(xc.load_cookies(self.path, now=2000))

if __name__ == "__main__":
    unittest.main()
