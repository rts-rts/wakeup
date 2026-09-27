import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from bot import Host, load_hosts, load_telegram_conf


def test_load_hosts(tmp_path):
    conf = tmp_path / "computers.conf"
    conf.write_text(
        "# comment\n"
        "\n"
        "  PC1 192.168.1.10 AA:BB:CC:DD:EE:FF\n"
        "NAS\t192.168.1.20\tDE:AD:BE:EF:CA:FE\tauto\n"
        "BROKEN 192.168.1.30\n"
        "LAST 192.168.1.40 11:22:33:44:55:66"  # без перевода строки в конце
    )
    assert load_hosts(conf) == [
        Host("PC1", "192.168.1.10", "AA:BB:CC:DD:EE:FF", False),
        Host("NAS", "192.168.1.20", "DE:AD:BE:EF:CA:FE", True),
        Host("LAST", "192.168.1.40", "11:22:33:44:55:66", False),
    ]


def test_load_telegram_conf(tmp_path):
    conf = tmp_path / "telegram.conf"
    conf.write_text('# comment\nBOT_TOKEN="123:abc"\nCHAT_ID="-1001234567890"\n')
    assert load_telegram_conf(conf) == ("123:abc", -1001234567890)
