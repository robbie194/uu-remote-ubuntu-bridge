from __future__ import annotations

import argparse
import importlib.machinery
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY = Path(__file__).resolve().parents[1]
HELPER = REPOSITORY / "scripts" / "configure-shared-desktop"
UNIT = REPOSITORY / "systemd" / "org.gnome.Shell@x11.service"

loader = importlib.machinery.SourceFileLoader("shared_desktop", str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
assert spec is not None
shared_desktop = importlib.util.module_from_spec(spec)
loader.exec_module(shared_desktop)


class SharedDesktopTests(unittest.TestCase):
    def test_cli_defaults_keep_native_ui_scale(self) -> None:
        arguments = shared_desktop.build_parser().parse_args(
            [
                "check",
                "--bus",
                "unix:path=/run/user/1000/bus",
                "--display",
                "auto",
                "--xauthority",
                "auto",
                "--config-dir",
                "/tmp/uu-remote-bridge",
            ]
        )

        self.assertEqual(1.0, arguments.text_scale)
        self.assertEqual("standard", arguments.desktop_icons)
        self.assertEqual(48, arguments.dock_icon_size)

    def test_recovery_unit_does_not_log_out_the_x11_session(self) -> None:
        unit = UNIT.read_text(encoding="utf-8")

        effective = "\n".join(
            line
            for line in unit.splitlines()
            if not line.lstrip().startswith("#")
        )
        self.assertNotIn("gnome-session-failed.target", effective)
        self.assertIn("OnFailure=org.gnome.Shell-disable-extensions.service", unit)
        self.assertIn("Restart=always", unit)
        self.assertIn("RestartSec=3s", unit)
        self.assertIn("StartLimitIntervalSec=120s", unit)
        self.assertIn("StartLimitBurst=10", unit)
        self.assertTrue(shared_desktop.validate_unit_source(UNIT))

    def test_mutter_target_preserves_unrelated_experimental_features(self) -> None:
        arguments = argparse.Namespace(
            text_scale=1.5,
            desktop_icons="large",
            dock_icon_size=57,
        )
        values = {
            ("org.gnome.mutter", "experimental-features"):
                "['variable-refresh-rate', 'scale-monitor-framebuffer', "
                "'x11-randr-fractional-scaling']",
            ("org.gnome.desktop.interface", "text-scaling-factor"): "1.0",
            ("org.gnome.shell.extensions.ding", "icon-size"): "'standard'",
            (
                "org.gnome.shell.extensions.dash-to-dock",
                "dash-max-icon-size",
            ): "38",
        }
        inventory = {
            schema: {key}
            for schema, key in shared_desktop.SETTING_SPECS.values()
        }
        with mock.patch.object(
            shared_desktop, "gsettings_inventory", return_value=inventory
        ), mock.patch.object(
            shared_desktop,
            "get_setting",
            side_effect=lambda _environment, schema, key: values[(schema, key)],
        ):
            desired, _ = shared_desktop.desired_settings({}, arguments)

        self.assertEqual(
            ["variable-refresh-rate"],
            shared_desktop.parse_string_array(
                desired["mutter_features"]["after"]
            ),
        )
        self.assertEqual("1.5", desired["text_scale"]["after"])
        self.assertEqual("'large'", desired["desktop_icons"]["after"])
        self.assertEqual("57", desired["dock_icon_size"]["after"])
        self.assertEqual("@as []", shared_desktop.render_string_array([]))

    def test_native_text_scale_matches_gsettings_serialization(self) -> None:
        arguments = argparse.Namespace(
            text_scale=1.0,
            desktop_icons="standard",
            dock_icon_size=48,
        )
        values = {
            ("org.gnome.mutter", "experimental-features"): "@as []",
            ("org.gnome.desktop.interface", "text-scaling-factor"): "1.0",
            ("org.gnome.shell.extensions.ding", "icon-size"): "'standard'",
            (
                "org.gnome.shell.extensions.dash-to-dock",
                "dash-max-icon-size",
            ): "48",
        }
        inventory = {
            schema: {key}
            for schema, key in shared_desktop.SETTING_SPECS.values()
        }
        with mock.patch.object(
            shared_desktop, "gsettings_inventory", return_value=inventory
        ), mock.patch.object(
            shared_desktop,
            "get_setting",
            side_effect=lambda _environment, schema, key: values[(schema, key)],
        ):
            desired, _ = shared_desktop.desired_settings({}, arguments)

        self.assertEqual("1.0", desired["text_scale"]["after"])

    def test_repair_action_is_available_without_geometry_changes(self) -> None:
        arguments = shared_desktop.build_parser().parse_args(
            [
                "repair",
                "--bus",
                "unix:path=/run/user/1000/bus",
                "--display",
                ":0",
                "--xauthority",
                "auto",
                "--config-dir",
                "/tmp/uu-remote-bridge",
                "--text-scale",
                "1.5",
                "--desktop-icons",
                "large",
                "--dock-icon-size",
                "57",
            ]
        )

        self.assertEqual("repair", arguments.action)
        self.assertEqual(1.5, arguments.text_scale)
        self.assertEqual("large", arguments.desktop_icons)
        self.assertEqual(57, arguments.dock_icon_size)

    def test_xrandr_parser_accepts_identity_and_rejects_fractional(self) -> None:
        identity = """DP-4 connected primary 2560x1440-2560+0
\tTransform:  1.000000 0.000000 0.000000
\t            0.000000 1.000000 0.000000
\t            0.000000 0.000000 1.000000
HDMI-1 disconnected
"""
        fractional = identity.replace(
            "1.000000 0.000000 0.000000",
            "0.750000 0.000000 0.000000",
            1,
        )

        parsed = shared_desktop.active_xrandr_transforms(identity)
        self.assertTrue(shared_desktop.is_identity_transform(parsed["DP-4"]))
        parsed = shared_desktop.active_xrandr_transforms(fractional)
        self.assertFalse(shared_desktop.is_identity_transform(parsed["DP-4"]))

    def test_desktop_resolution_accepts_only_the_active_seat0_display(self) -> None:
        physical = {
            "DISPLAY": ":0",
            "XAUTHORITY": "/run/user/1000/gdm/Xauthority",
        }
        with mock.patch.object(
            shared_desktop,
            "physical_x11_environments",
            return_value=[physical],
        ), mock.patch.object(
            shared_desktop, "systemd_shell_pid", return_value=123
        ), mock.patch.object(
            shared_desktop,
            "read_process_environment",
            return_value={"DISPLAY": ":10", "XAUTHORITY": "/xrdp/auth"},
        ):
            self.assertEqual(
                (":0", "/run/user/1000/gdm/Xauthority"),
                shared_desktop.resolve_desktop("unix:path=/bus", "auto", "auto"),
            )
            with self.assertRaises(shared_desktop.ConfigurationError):
                shared_desktop.resolve_desktop(
                    "unix:path=/bus", ":10", "/xrdp/auth"
                )

    def test_managed_profile_rejects_unit_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "config"
            target = root / "org.gnome.Shell@x11.service"
            managed = b"[Service]\nRestart=always\n"
            target.write_bytes(managed)
            shared_desktop.save_state(
                config,
                {
                    "schema_version": 1,
                    "active": True,
                    "settings": {},
                    "unit": {
                        "target": str(target),
                        "managed_after_sha256": shared_desktop.sha256(managed),
                    },
                },
            )
            effective = mock.Mock(
                stdout=(
                    f"FragmentPath={target}\n"
                    "OnFailure=org.gnome.Shell-disable-extensions.service\n"
                    "Restart=always\n"
                    "RestartUSec=3s\n"
                    "StartLimitBurst=10\n"
                    "StartLimitIntervalUSec=2min\n"
                )
            )
            with mock.patch.object(
                shared_desktop, "run_command", return_value=effective
            ), mock.patch.object(
                shared_desktop, "command_path", return_value="systemctl"
            ):
                shared_desktop.check_managed_profile(config, {})
                target.write_text("locally changed\n", encoding="utf-8")
                with self.assertRaises(shared_desktop.ConfigurationError):
                    shared_desktop.check_managed_profile(config, {})

    def test_failed_enable_rolls_back_managed_values_and_unit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "config"
            source = root / "source.service"
            target = root / "target.service"
            source.write_text("[Service]\nRestart=always\n", encoding="utf-8")
            legacy = (
                "[Unit]\n"
                "Description=GNOME Shell on X11 with physical-session recovery\n"
                "OnFailure=org.gnome.Shell-disable-extensions.service\n"
                "[Service]\nRestart=always\n"
            )
            target.write_text(legacy, encoding="utf-8")
            dropin = target.parent / (
                f"{shared_desktop.SHELL_UNIT_NAME}.d/"
                "90-uu-remote-recovery.conf"
            )
            dropin.parent.mkdir()
            dropin.write_text(
                "# Keep the physical X11 session alive when Mutter crashes\n"
                "[Service]\nRestartSec=3s\n",
                encoding="utf-8",
            )
            arguments = argparse.Namespace(
                config_dir=str(config),
                unit_source=str(source),
                text_scale=1.5,
                desktop_icons="large",
                dock_icon_size=57,
            )
            desired = {
                "text_scale": {
                    "schema": "org.gnome.desktop.interface",
                    "key": "text-scaling-factor",
                    "before": "1.0",
                    "after": "1.5",
                }
            }
            with mock.patch.object(
                shared_desktop, "unit_target", return_value=target
            ), mock.patch.object(
                shared_desktop, "desired_settings", return_value=(desired, {})
            ), mock.patch.object(
                shared_desktop, "check_identity_geometry"
            ), mock.patch.object(
                shared_desktop, "get_setting", return_value="1.5"
            ), mock.patch.object(
                shared_desktop, "set_setting"
            ) as setter, mock.patch.object(
                shared_desktop, "reload_user_manager"
            ), mock.patch.object(
                shared_desktop,
                "check_safety",
                side_effect=shared_desktop.ConfigurationError("unsafe"),
            ):
                with self.assertRaises(shared_desktop.ConfigurationError):
                    shared_desktop.enable(arguments, {})

            self.assertEqual(legacy, target.read_text(encoding="utf-8"))
            self.assertTrue(dropin.exists())
            state = shared_desktop.load_state(config)
            self.assertIsNone(state)
            self.assertGreaterEqual(setter.call_count, 2)

    def test_active_reconfigure_refuses_a_user_modified_unit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "config"
            source = root / "source.service"
            target = root / "target.service"
            source.write_text("[Service]\nRestart=always\n", encoding="utf-8")
            target.write_text("user modified\n", encoding="utf-8")
            shared_desktop.save_state(
                config,
                {
                    "schema_version": 1,
                    "active": True,
                    "settings": {},
                    "unit": {
                        "target": str(target),
                        "managed_after_sha256": shared_desktop.sha256(b"old"),
                    },
                },
            )
            arguments = argparse.Namespace(
                config_dir=str(config),
                unit_source=str(source),
                text_scale=1.5,
                desktop_icons="large",
                dock_icon_size=57,
            )
            with mock.patch.object(
                shared_desktop, "unit_target", return_value=target
            ), mock.patch.object(
                shared_desktop, "desired_settings", return_value=({}, {})
            ), mock.patch.object(
                shared_desktop, "check_identity_geometry"
            ), self.assertRaises(shared_desktop.ConfigurationError):
                shared_desktop.enable(arguments, {})

            self.assertEqual("user modified\n", target.read_text(encoding="utf-8"))

    def test_failed_active_reconfigure_restores_previous_profile(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "config"
            source = root / "source.service"
            target = root / "target.service"
            previous_unit = b"[Service]\nRestart=always\n# previous\n"
            source.write_bytes(b"[Service]\nRestart=always\n# new\n")
            target.write_bytes(previous_unit)
            previous_state = {
                "schema_version": 1,
                "active": True,
                "settings": {
                    "text_scale": {
                        "schema": "org.gnome.desktop.interface",
                        "key": "text-scaling-factor",
                        "before": "1.0",
                        "after": "1.5",
                    }
                },
                "unit": {
                    "target": str(target),
                    "before_present": False,
                    "before_content": "",
                    "before_mode": 0,
                    "managed_after_sha256": shared_desktop.sha256(previous_unit),
                },
            }
            shared_desktop.save_state(config, previous_state)
            desired = {
                "text_scale": {
                    "schema": "org.gnome.desktop.interface",
                    "key": "text-scaling-factor",
                    "before": "1.5",
                    "after": "1.6",
                }
            }
            arguments = argparse.Namespace(
                config_dir=str(config),
                unit_source=str(source),
                text_scale=1.6,
                desktop_icons="large",
                dock_icon_size=57,
            )
            with mock.patch.object(
                shared_desktop, "unit_target", return_value=target
            ), mock.patch.object(
                shared_desktop, "desired_settings", return_value=(desired, {})
            ), mock.patch.object(
                shared_desktop, "check_identity_geometry"
            ), mock.patch.object(
                shared_desktop, "set_setting"
            ) as setter, mock.patch.object(
                shared_desktop, "reload_user_manager"
            ), mock.patch.object(
                shared_desktop,
                "check_safety",
                side_effect=shared_desktop.ConfigurationError("unsafe"),
            ):
                with self.assertRaises(shared_desktop.ConfigurationError):
                    shared_desktop.enable(arguments, {})

            self.assertEqual(previous_unit, target.read_bytes())
            self.assertEqual(previous_state, shared_desktop.load_state(config))
            self.assertEqual("1.5", setter.call_args_list[-1].args[-1])

    def test_reenable_uses_the_current_inactive_settings_as_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "config"
            source = root / "source.service"
            target = root / "target.service"
            source.write_text("[Service]\nRestart=always\n", encoding="utf-8")
            shared_desktop.save_state(
                config,
                {
                    "schema_version": 1,
                    "active": False,
                    "settings": {
                        "text_scale": {
                            "schema": "org.gnome.desktop.interface",
                            "key": "text-scaling-factor",
                            "before": "1.0",
                            "after": "1.5",
                        }
                    },
                    "unit": {
                        "target": str(target),
                        "before_present": False,
                        "before_content": "",
                        "before_mode": 0,
                        "managed_after_sha256": "old",
                    },
                },
            )
            desired = {
                "text_scale": {
                    "schema": "org.gnome.desktop.interface",
                    "key": "text-scaling-factor",
                    "before": "1.25",
                    "after": "1.5",
                }
            }
            arguments = argparse.Namespace(
                config_dir=str(config),
                unit_source=str(source),
                text_scale=1.5,
                desktop_icons="large",
                dock_icon_size=57,
            )
            with mock.patch.object(
                shared_desktop, "unit_target", return_value=target
            ), mock.patch.object(
                shared_desktop, "desired_settings", return_value=(desired, {})
            ), mock.patch.object(
                shared_desktop, "check_identity_geometry"
            ), mock.patch.object(
                shared_desktop, "set_setting"
            ), mock.patch.object(
                shared_desktop, "reload_user_manager"
            ), mock.patch.object(
                shared_desktop, "check_safety"
            ), mock.patch.object(shared_desktop, "check_managed_profile"):
                shared_desktop.enable(arguments, {})

            state = shared_desktop.load_state(config)
            assert state is not None
            self.assertEqual("1.25", state["settings"]["text_scale"]["before"])

    def test_first_enable_backup_is_not_overwritten(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "config"
            source = root / "source.service"
            target = root / "target.service"
            source.write_text("[Service]\nRestart=always\n", encoding="utf-8")
            target.write_text("original unit\n", encoding="utf-8")
            arguments = argparse.Namespace(
                config_dir=str(config),
                unit_source=str(source),
                text_scale=1.5,
                desktop_icons="large",
                dock_icon_size=57,
            )
            desired = {
                "text_scale": {
                    "schema": "org.gnome.desktop.interface",
                    "key": "text-scaling-factor",
                    "before": "1.0",
                    "after": "1.5",
                }
            }
            with mock.patch.object(
                shared_desktop, "unit_target", return_value=target
            ), mock.patch.object(
                shared_desktop, "desired_settings", return_value=(desired, {})
            ), mock.patch.object(shared_desktop, "set_setting"), mock.patch.object(
                shared_desktop, "reload_user_manager"
            ), mock.patch.object(
                shared_desktop, "check_identity_geometry"
            ), mock.patch.object(
                shared_desktop, "check_safety"
            ), mock.patch.object(shared_desktop, "check_managed_profile"):
                shared_desktop.enable(arguments, {})
                desired["text_scale"]["before"] = "1.5"
                shared_desktop.enable(arguments, {})

            state = json.loads(
                (config / shared_desktop.STATE_NAME).read_text(encoding="utf-8")
            )
            self.assertEqual("1.0", state["settings"]["text_scale"]["before"])
            self.assertTrue(state["unit"]["before_present"])

    def test_disable_restores_only_unchanged_managed_values(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "config"
            target = root / "target.service"
            managed = b"[Service]\nRestart=always\n"
            target.write_bytes(managed)
            state = {
                "schema_version": 1,
                "active": True,
                "settings": {
                    "text_scale": {
                        "schema": "org.gnome.desktop.interface",
                        "key": "text-scaling-factor",
                        "before": "1.0",
                        "after": "1.5",
                    },
                    "desktop_icons": {
                        "schema": "org.gnome.shell.extensions.ding",
                        "key": "icon-size",
                        "before": "'standard'",
                        "after": "'large'",
                    },
                },
                "unit": {
                    "target": str(target),
                    "before_present": False,
                    "before_content": "",
                    "before_mode": 0,
                    "managed_after_sha256": shared_desktop.sha256(managed),
                },
            }
            shared_desktop.save_state(config, state)
            current = {
                ("org.gnome.desktop.interface", "text-scaling-factor"): "1.5",
                ("org.gnome.shell.extensions.ding", "icon-size"): "'small'",
            }
            arguments = argparse.Namespace(config_dir=str(config))
            with mock.patch.object(
                shared_desktop,
                "get_setting",
                side_effect=lambda _environment, schema, key: current[(schema, key)],
            ), mock.patch.object(
                shared_desktop, "set_setting"
            ) as setter, mock.patch.object(shared_desktop, "reload_user_manager"):
                shared_desktop.disable(arguments, {})

            setter.assert_called_once_with(
                {},
                "org.gnome.desktop.interface",
                "text-scaling-factor",
                "1.0",
            )
            self.assertFalse(target.exists())
            restored = shared_desktop.load_state(config)
            assert restored is not None
            self.assertFalse(restored["active"])

    def test_failed_disable_restores_the_active_profile(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "config"
            target = root / "target.service"
            managed = b"[Service]\nRestart=always\n"
            target.write_bytes(managed)
            state = {
                "schema_version": 1,
                "active": True,
                "settings": {
                    "text_scale": {
                        "schema": "org.gnome.desktop.interface",
                        "key": "text-scaling-factor",
                        "before": "1.0",
                        "after": "1.5",
                    }
                },
                "unit": {
                    "target": str(target),
                    "before_present": False,
                    "before_content": "",
                    "before_mode": 0,
                    "managed_after_sha256": shared_desktop.sha256(managed),
                },
            }
            shared_desktop.save_state(config, state)
            failed = False

            def set_value(_environment, _schema, _key, value):
                nonlocal failed
                if value == "1.0" and not failed:
                    failed = True
                    raise shared_desktop.ConfigurationError("write failed")

            arguments = argparse.Namespace(config_dir=str(config))
            with mock.patch.object(
                shared_desktop, "get_setting", return_value="1.5"
            ), mock.patch.object(
                shared_desktop, "set_setting", side_effect=set_value
            ), mock.patch.object(shared_desktop, "reload_user_manager"):
                with self.assertRaises(shared_desktop.ConfigurationError):
                    shared_desktop.disable(arguments, {})

            self.assertEqual(managed, target.read_bytes())
            self.assertEqual(state, shared_desktop.load_state(config))


if __name__ == "__main__":
    unittest.main()
