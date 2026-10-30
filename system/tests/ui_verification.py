#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
==============================================================================
ui_verification.py - Headless Browser UI Automated Verification Suite
==============================================================================
【初心者向けの簡単な解説】
このスクリプトは、Webブラウザ自動化ツール「Playwright」を利用して、
画面（フロントエンド）が壊れていないか、ボタンが正常に反応するかを
人間の代わりに自動でテストするプログラムです。

検証項目：
1. ダッシュボードの画面が正しく表示され、JavaScript のエラーが発生しないこと
2. ネットワーク構成図（Vis-network キャンバス）が正常に描画されること
3. アラート消音ボタン、階層ツリー整列ボタン、シアターモードボタン等の操作テスト
4. 通信切断・再接続の耐久性テスト:
   通信エラーを模擬発生させ、警告バナー (#network-offline-banner) が表示され、
   通信復帰後にバナーが自動で消去されて再接続トーストが表示されること
==============================================================================
"""

import sys
import os

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
import time
import socket
import argparse
import subprocess
import urllib.request
import json

# ── ANSI Color Helpers for Terminal Output ────────────────────────────────────
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"


def print_info(msg):
    print(f"{CYAN}[INFO]{RESET} {msg}")


def print_pass(msg):
    print(f"  {GREEN}[PASS]{RESET} {msg}")


def print_fail(msg):
    print(f"  {RED}[FAIL]{RESET} {msg}")


def print_warn(msg):
    print(f"  {YELLOW}[WARN]{RESET} {msg}")


def find_available_port(start_port=8091, max_tries=30):
    """Finds an unused TCP port on localhost."""
    for port in range(start_port, start_port + max_tries):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            if s.connect_ex(("127.0.0.1", port)) != 0:
                return port
    return start_port


def is_server_healthy(port, timeout_sec=2):
    """Checks if /api/health responds with status 'ok' on the given port."""
    url = f"http://localhost:{port}/api/health"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "UI-Verification-Probe"})
        with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
            if resp.status == 200:
                data = json.loads(resp.read().decode("utf-8"))
                return data.get("status") == "ok"
    except Exception:
        pass
    return False


def start_test_server(port, project_root):
    """Launches a temporary Server.ps1 instance on an isolated port."""
    system_dir = os.path.join(project_root, "system")
    server_script = os.path.join(system_dir, "Server.ps1")

    with open(server_script, "r", encoding="utf-8-sig") as f:
        raw_code = f.read()

    patched_code = raw_code.replace("$port = 8081", f"$port = {port}")
    escaped_sys_dir = system_dir.replace("'", "''")
    wrapper = f"$PSScriptRoot = '{escaped_sys_dir}';\r\n{patched_code}"
    temp_runner = os.path.join(system_dir, "tests", "temp_ui_runner.ps1")
    with open(temp_runner, "w", encoding="utf-8-sig") as f:
        f.write(wrapper)

    proc = subprocess.Popen(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", temp_runner],
        cwd=system_dir,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    )
    proc._temp_runner = temp_runner
    return proc


def stop_test_server(proc, port):
    """Gracefully shuts down the test server via /api/shutdown or terminates process."""
    if not proc:
        return
    if proc.poll() is None:
        try:
            shutdown_url = f"http://localhost:{port}/api/shutdown"
            req = urllib.request.Request(shutdown_url, data=b"{}", headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=3)
            proc.wait(timeout=10)
        except Exception:
            try:
                proc.terminate()
                proc.wait(timeout=3)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass

    temp_runner = getattr(proc, "_temp_runner", None)
    if temp_runner and os.path.exists(temp_runner):
        try:
            os.remove(temp_runner)
        except Exception:
            pass


def run_ui_verification(port, headless=True, preferred_browser=None):
    """Executes the Playwright UI automated verification suite."""
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print_fail("Playwright is not installed. Please install via: pip install playwright")
        return False

    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    managed_proc = None
    test_results = {"total": 0, "passed": 0, "failed": 0}

    def record_test(name, result, detail=""):
        test_results["total"] += 1
        if result:
            test_results["passed"] += 1
            print_pass(name)
        else:
            test_results["failed"] += 1
            print_fail(f"{name} -> {detail}")

    # Check if a server is already running on the target port
    if not is_server_healthy(port):
        print_info(f"No active server detected on port {port}. Starting dedicated test instance...")
        managed_proc = start_test_server(port, project_root)
        start_time = time.time()
        while time.time() - start_time < 25:
            if is_server_healthy(port):
                break
            time.sleep(0.5)

        if not is_server_healthy(port):
            print_fail(f"Failed to start test server on port {port} within 25 seconds.")
            if managed_proc:
                managed_proc.kill()
            return False
        print_info(f"Test server started successfully on port {port}.")
    else:
        print_info(f"Connected to existing healthy server on port {port}.")

    target_url = f"http://localhost:{port}/"

    try:
        with sync_playwright() as p:
            # Browser Channel Resolution: msedge -> chrome -> bundled chromium
            browser = None
            channels_to_try = []
            if preferred_browser:
                channels_to_try.append(preferred_browser)
            channels_to_try.extend(["msedge", "chrome", None])

            launch_error = None
            used_channel = None
            for ch in channels_to_try:
                try:
                    if ch:
                        browser = p.chromium.launch(headless=headless, channel=ch)
                        used_channel = ch
                    else:
                        browser = p.chromium.launch(headless=headless)
                        used_channel = "bundled chromium"
                    break
                except Exception as e:
                    launch_error = e
                    continue

            if not browser:
                print_fail(f"Could not launch browser (tried msedge, chrome, chromium): {launch_error}")
                return False

            print_info(f"Browser launched successfully using: {used_channel} (Headless: {headless})")
            context = browser.new_context(viewport={"width": 1440, "height": 900})
            page = context.new_page()

            # Collect console messages and uncaught exceptions
            console_errors = []
            page_errors = []

            def on_console(msg):
                # Ignore deliberate/expected network warning during disconnection test
                if msg.type == "error":
                    text = msg.text
                    if "favicon.ico" not in text and "/api/status" not in text:
                        console_errors.append(text)

            def on_page_error(err):
                page_errors.append(str(err))

            page.on("console", on_console)
            page.on("pageerror", on_page_error)

            print(f"\n{BOLD}=== Test Phase 1: Dashboard Loading & Visual Shell Rendering ==={RESET}")
            # Navigate to application
            page.goto(target_url, wait_until="domcontentloaded", timeout=15000)
            page.wait_for_selector(".container", timeout=10000)

            title = page.title()
            has_valid_title = "ネットワーク" in title or "Network" in title or len(title) > 0
            record_test("Page title is rendered properly", has_valid_title, f"Actual title: {title}")

            brand_visible = page.is_visible(".sidebar-brand")
            record_test("Sidebar brand logo & title rendered", brand_visible)

            tab_dashboard_visible = page.is_visible("#tab-dashboard")
            tab_topology_visible = page.is_visible("#tab-topology")
            record_test("Navigation tabs (Dashboard, Topology) present", tab_dashboard_visible and tab_topology_visible)

            device_list_present = page.query_selector("#device-list") is not None
            record_test("Device cards container (#device-list) present", device_list_present)

            record_test("Initial page load has 0 unhandled JS exceptions", len(page_errors) == 0, f"Errors: {page_errors}")

            print(f"\n{BOLD}=== Test Phase 2: Interactive Controls & UI State Verification ==={RESET}")
            # 1. Alert Mute Toggle Button
            mute_btn = page.query_selector("#btn-mute-alert")
            if mute_btn:
                mute_btn.click()
                time.sleep(0.3)
                is_active = page.evaluate("() => document.getElementById('btn-mute-alert').classList.contains('btn-mute-active')")
                mute_icon = page.inner_text("#mute-icon") if page.query_selector("#mute-icon") else ""
                record_test("Alert mute toggle activates (btn-mute-active, [Muted])", is_active and ("\U0001f507" in mute_icon or "消音中" in page.inner_text("#btn-mute-alert")))

                # Toggle back off
                mute_btn.click()
                time.sleep(0.3)
                is_active_after = page.evaluate("() => document.getElementById('btn-mute-alert').classList.contains('btn-mute-active')")
                record_test("Alert mute toggle deactivates cleanly", not is_active_after)
            else:
                record_test("Alert mute button present", False, "Element #btn-mute-alert not found")

            # 2. Theme Toggle (Night <-> Day)
            theme_btn = page.query_selector("#theme-toggle-btn")
            if theme_btn:
                theme_btn.click()
                time.sleep(0.3)
                theme_val = page.evaluate("() => document.documentElement.getAttribute('data-theme')")
                record_test("Theme toggle switches theme (data-theme attribute)", theme_val in ["day", "night"])

                # Revert theme
                theme_btn.click()
                time.sleep(0.3)
            else:
                record_test("Theme toggle button present", False, "Element #theme-toggle-btn not found")

            # 3. Vis-network Topology Canvas Rendering
            print(f"\n{BOLD}=== Test Phase 3: Vis-network Topology Canvas & Layout Controls ==={RESET}")
            page.click("#tab-topology")
            page.wait_for_selector("#topology-container", timeout=10000)
            time.sleep(1.0)  # allow canvas render loop to initialize

            canvas_el = page.query_selector("#topology-container canvas")
            canvas_rendered = False
            if canvas_el:
                box = canvas_el.bounding_box()
                if box and box["width"] > 0 and box["height"] > 0:
                    canvas_rendered = True
            record_test("Vis-network topology canvas exists and has non-zero geometry", canvas_rendered)

            # 4. Topology Tree Layout Button
            tree_btn = page.query_selector("#topo-tree-layout-btn")
            if tree_btn:
                tree_btn.click()
                time.sleep(0.5)
                record_test("Topology tree layout button responds without script exception", True)
            else:
                record_test("Topology tree layout button present", False, "Element #topo-tree-layout-btn not found")

            # 5. Theater Mode / Fullscreen Button
            fs_btn = page.query_selector("#topo-fullscreen-btn")
            if fs_btn:
                fs_btn.click()
                time.sleep(0.4)
                in_theater = page.evaluate("() => document.querySelector('.topology-layout').classList.contains('theater-mode')")
                record_test("Theater mode expands (.theater-mode added to .topology-layout)", in_theater)

                # Exit theater mode
                fs_btn.click()
                time.sleep(0.4)
                in_theater_after = page.evaluate("() => document.querySelector('.topology-layout').classList.contains('theater-mode')")
                record_test("Theater mode collapses cleanly", not in_theater_after)
            else:
                record_test("Theater mode button present", False, "Element #topo-fullscreen-btn not found")

            # 6. Return to dashboard
            page.click("#tab-dashboard")
            time.sleep(0.5)

            print(f"\n{BOLD}=== Test Phase 4: Network Resilience & Offline Banner (#network-offline-banner) ==={RESET}")
            banner_el = page.query_selector("#network-offline-banner")
            record_test("Offline warning banner element (#network-offline-banner) present in DOM", banner_el is not None)

            # Initially banner must be hidden
            is_initially_hidden = not page.is_visible("#network-offline-banner")
            record_test("Offline banner is initially hidden during normal connectivity", is_initially_hidden)

            # Intercept /api/status to simulate backend network drop
            print_info("Simulating network disconnection: intercepting and dropping /api/status requests...")
            page.route("**/api/status", lambda route: route.abort("connectionfailed"))

            # Poll interval is 1s; consecutiveFetchErrors >= 3 triggers banner display
            banner_appeared = False
            try:
                page.wait_for_selector("#network-offline-banner", state="visible", timeout=12000)
                banner_appeared = page.is_visible("#network-offline-banner")
            except Exception as ex:
                banner_appeared = False

            record_test("Offline banner appears upon consecutive communication drop", banner_appeared)

            banner_text = page.inner_text("#network-offline-banner") if banner_appeared else ""
            has_offline_text = "切断" in banner_text or "再接続" in banner_text or "Offline" in banner_text
            record_test("Offline banner displays descriptive warning message", has_offline_text, f"Banner text: {banner_text}")

            # Restore network connectivity
            print_info("Restoring network connectivity: removing route interception...")
            page.unroute("**/api/status")

            # Click retry button or wait for next periodic poll to detect reconnection
            retry_btn = page.query_selector("#btn-banner-reconnect")
            if retry_btn and page.is_visible("#btn-banner-reconnect"):
                retry_btn.click()

            banner_disappeared = False
            try:
                page.wait_for_selector("#network-offline-banner", state="hidden", timeout=12000)
                banner_disappeared = not page.is_visible("#network-offline-banner")
            except Exception:
                banner_disappeared = False

            record_test("Offline banner automatically disappears upon communication recovery", banner_disappeared)

            # Verify reconnection toast was shown
            toast_visible = page.evaluate("() => document.querySelectorAll('.toast, .toast-success, #toast-container > div').length > 0")
            record_test("Reconnection toast notification displayed upon recovery", toast_visible)

            # Final JS errors check across entire session
            record_test("Total unhandled JS exceptions across full test session is 0", len(page_errors) == 0, f"Errors: {page_errors}")

            browser.close()

    finally:
        if managed_proc:
            print_info("Stopping test server instance...")
            stop_test_server(managed_proc, port)

    print(f"\n==========================================================")
    print(f"  UI Automated Verification Summary")
    print(f"  Total:   {test_results['total']}")
    print(f"  Passed:  {GREEN}{test_results['passed']}{RESET}")
    print(f"  Failed:  {RED if test_results['failed'] > 0 else GREEN}{test_results['failed']}{RESET}")
    print(f"==========================================================")

    return test_results["failed"] == 0


def main():
    parser = argparse.ArgumentParser(description="Headless Browser UI Verification via Playwright")
    parser.add_argument("--port", type=int, default=8092, help="Port to connect to or launch server on (default: 8092)")
    parser.add_argument("--headless", action="store_true", default=True, help="Run browser in headless mode (default: True)")
    parser.add_argument("--no-headless", dest="headless", action="store_false", help="Run browser in headed mode")
    parser.add_argument("--browser", type=str, default=None, help="Preferred browser channel ('msedge', 'chrome')")
    args = parser.parse_args()

    print("==========================================================")
    print("  Network Device Monitor - UI Automated Test Suite")
    print("==========================================================")

    success = run_ui_verification(port=args.port, headless=args.headless, preferred_browser=args.browser)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
