from __future__ import annotations

import argparse
import posixpath
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable

from PySide6.QtCore import QObject, QRunnable, Qt, QThreadPool, QTimer, Signal
from PySide6.QtGui import QAction, QColor, QIcon, QPainter, QPen, QPixmap
from PySide6.QtWidgets import (
    QAbstractItemView,
    QApplication,
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFrame,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QListWidget,
    QMainWindow,
    QMenu,
    QMessageBox,
    QPlainTextEdit,
    QPushButton,
    QStackedWidget,
    QSystemTrayIcon,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from . import demo, platform_support
from .core import (
    KNOWN_HOSTS_FILE,
    PROFILES,
    SETTINGS_FILE,
    LocalStore,
    validate_snapshot,
    validate_username,
)
from .rules import (
    StorageTracker,
    card_heading,
    card_summary,
    cluster_figures,
    cpu_summary,
    gpu_fleet,
    history_gpu_text,
    history_point,
    job_change_messages,
    job_details_text,
    job_display_fields,
    job_sort_key,
    local_time_text,
    node_display_fields,
    partition_display_fields,
    pool_lines,
    storage_display_fields,
    storage_rows_time,
    storage_summary,
    trend_points,
)
from .ssh import AuthenticationRejected, Cancelled, ConnectionManager, HostVerifier

# Window titles, labels and messages that name the platform or its
# credential store; everything else is identical on Windows and Linux.
PLATFORM = platform_support.texts()

STYLE_TEMPLATE = """
QWidget { background: #101820; color: #e5edf3; font-family: FONT_FAMILY; font-size: 13px; }
QMainWindow, QDialog { background: #101820; }
QFrame#sidebar { background: #141f29; border-right: 1px solid #283846; }
QFrame#card { background: #182630; border: 1px solid #30434f; border-radius: 12px; }
QFrame#card QLabel { background: transparent; }
QLabel#title { font-size: 28px; font-weight: 600; }
QLabel#brand { font-size: 19px; font-weight: 600; }
QLabel#muted { color: #a5b8c6; }
QLabel#accent { color: #72dec0; font-weight: 600; }
QLabel#banner { color: #ffe1a3; background: #3c321f; padding: 10px; border-radius: 6px; }
QPushButton { background: #243846; border: 1px solid #3b5363; border-radius: 5px; padding: 8px 14px; }
QPushButton:hover { background: #315365; }
QPushButton:disabled { color: #748794; background: #1b2832; }
QPushButton#primary { background: #137e65; border-color: #219d7f; color: white; font-weight: 600; }
QPushButton#primary:hover { background: #19967a; }
QLineEdit, QComboBox, QPlainTextEdit { background: #0d151c; border: 1px solid #39505f; border-radius: 4px; padding: 7px; }
QComboBox QAbstractItemView { background: #182630; selection-background-color: #285445; }
QListWidget { background: transparent; border: 0; outline: 0; }
QListWidget::item { padding: 11px; border-radius: 5px; margin: 2px 0; }
QListWidget::item:selected { background: #23473e; color: #a5f2da; }
QTableWidget { background: #111c25; alternate-background-color: #17242e; border: 1px solid #2c414f; gridline-color: #273a47; }
QTableWidget::item { padding: 6px; }
QTableWidget::item:selected { background: #285343; }
QHeaderView::section { background: #1f303c; color: #c1d1dd; border: 0; padding: 10px; font-weight: 600; }
QScrollArea { border: 0; }
QToolTip { background: #213542; color: white; border: 1px solid #6c8b9b; }
"""
# The platform's font stack; the stylesheet's braces rule out an f-string.
STYLE = STYLE_TEMPLATE.replace("FONT_FAMILY", PLATFORM.font_family)


def label(text, name="", wrap=False):
    widget = QLabel(str(text))
    widget.setTextFormat(Qt.TextFormat.PlainText)
    widget.setObjectName(name)
    widget.setWordWrap(wrap)
    return widget


def button(text, callback, primary=False):
    widget = QPushButton(text)
    widget.clicked.connect(callback)
    if primary:
        widget.setObjectName("primary")
    return widget


def display(value):
    if value is None:
        return "—"
    if isinstance(value, list):
        return ", ".join(map(str, value))
    if isinstance(value, float):
        return f"{value:,.1f}"
    return str(value)


def table(columns):
    widget = QTableWidget(0, len(columns))
    widget.setHorizontalHeaderLabels([c[0] for c in columns])
    widget.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
    widget.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
    widget.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
    widget.setAlternatingRowColors(True)
    widget.verticalHeader().hide()
    widget.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.ResizeToContents)
    widget.horizontalHeader().setStretchLastSection(True)
    widget.verticalHeader().setDefaultSectionSize(36)
    return widget


# Text colours for rows whose "_tone" asks for attention (storage at 75 %
# and 90 % pressure, or over quota), the same thresholds as the macOS app.
TONE_COLOURS = {"warning": "#ffd27a", "critical": "#ff8a80"}


def fill_table(widget, columns, rows):
    widget.setSortingEnabled(False)
    widget.setRowCount(len(rows))
    for row, data in enumerate(rows):
        tone = TONE_COLOURS.get(data.get("_tone", ""))
        for col, (_, key) in enumerate(columns):
            item = QTableWidgetItem(display(data.get(key)))
            item.setData(Qt.ItemDataRole.UserRole, data)
            if tone:
                item.setForeground(QColor(tone))
            widget.setItem(row, col, item)
    widget.setSortingEnabled(True)


class TaskSignals(QObject):
    done = Signal(object, object)


class Task(QRunnable):
    def __init__(self, function, callback):
        super().__init__()
        self.function: Callable[[], object] | None = function
        self.signals = TaskSignals()
        self.signals.done.connect(callback)

    def run(self):
        function = self.function
        if function is None:
            return
        try:
            value, error = function(), None
        except Exception as exc:
            value, error = None, exc
        self.function = None
        self.signals.done.emit(value, error)


@dataclass
class Prompt:
    kind: str
    host: str
    content: object
    event: threading.Event = field(default_factory=threading.Event)
    result: object = None


class PromptBridge(QObject):
    requested = Signal(object)

    def __init__(self, parent: QWidget):
        super().__init__(parent)
        self.owner = parent
        self.requested.connect(self.show_prompt)
        self.closing = threading.Event()
        self.pending = []

    def ask(self, kind, host, content):
        prompt = Prompt(kind, host, content)
        self.pending.append(prompt)
        self.requested.emit(prompt)
        deadline = datetime.now(timezone.utc).timestamp() + 180
        while not prompt.event.wait(0.2):
            if self.closing.is_set() or datetime.now(timezone.utc).timestamp() >= deadline:
                break
        self.pending.remove(prompt)
        return prompt.result

    def close(self):
        self.closing.set()
        for prompt in self.pending[:]:
            prompt.event.set()

    def show_prompt(self, prompt):
        if self.closing.is_set() or prompt.event.is_set():
            prompt.event.set()
            return
        if prompt.kind == "host":
            box = QMessageBox(self.owner)
            box.setWindowTitle("Verify SSH host key")
            box.setTextFormat(Qt.TextFormat.PlainText)
            box.setText(
                f"First connection to {prompt.host}\n\n{prompt.content}\n\n"
                "Compare this fingerprint with Leeds IT or a trusted connection before accepting. "
                "A password has not been sent yet."
            )
            box.setStandardButtons(QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No)
            box.setDefaultButton(QMessageBox.StandardButton.No)
            prompt.result = box.exec() == QMessageBox.StandardButton.Yes
        else:
            title, instructions, text, echo = prompt.content
            dialog = QDialog(self.owner)
            dialog.setWindowTitle(f"SSH authentication · {prompt.host}")
            layout = QVBoxLayout(dialog)
            layout.addWidget(label(f"{title}\n{instructions}\n{text}", wrap=True))
            answer = QLineEdit()
            answer.setEchoMode(QLineEdit.EchoMode.Normal if echo else QLineEdit.EchoMode.Password)
            layout.addWidget(answer)
            controls = QDialogButtonBox(
                QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
            )
            controls.accepted.connect(dialog.accept)
            controls.rejected.connect(dialog.reject)
            layout.addWidget(controls)
            prompt.result = answer.text() if dialog.exec() == QDialog.DialogCode.Accepted else None
        prompt.event.set()


class TrendPlot(QWidget):
    def __init__(self):
        super().__init__()
        self.series = []
        self.setMinimumHeight(260)

    def set_series(self, series):
        self.series = series
        self.update()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        area = self.rect().adjusted(42, 25, -25, -40)
        valid = [(p, trend_points(history)) for p, history in self.series]
        values = [v for _, history in valid for _, v in history]
        times = [t for _, history in valid for t, _ in history]
        maximum = max(values, default=1) or 1
        start, end = min(times, default=0), max(times, default=1)
        for i in range(5):
            y = area.bottom() - area.height() * i / 4
            painter.setPen(QColor("#2b404d"))
            painter.drawLine(area.left(), int(y), area.right(), int(y))
            painter.setPen(QColor("#9fb3c3"))
            painter.drawText(2, int(y + 4), str(round(maximum * i / 4)))
        for p, history in valid:
            painter.setPen(QPen(QColor(p.color), 2))
            previous = None
            for stamp, value in history:
                point = (
                    int(area.left() + (stamp - start) / max(1, end - start) * area.width()),
                    int(area.bottom() - value / maximum * area.height()),
                )
                if previous:
                    painter.drawLine(*previous, *point)
                previous = point
        painter.setPen(QColor("#9fb3c3"))
        if times:
            painter.drawText(
                area.left(), self.height() - 10, datetime.fromtimestamp(start).strftime("%d %b %H:%M")
            )
            painter.drawText(
                area.right() - 110, self.height() - 10, datetime.fromtimestamp(end).strftime("%d %b %H:%M")
            )
        else:
            painter.drawText(area, Qt.AlignmentFlag.AlignCenter, "History appears after the first refresh.")


class FileBrowser(QDialog):
    def __init__(self, window, profile, path):
        super().__init__(window)
        self.owner, self.profile, self.entries = window, profile, []
        self.setWindowTitle(f"{profile.name} · Read-only files")
        self.resize(1000, 700)
        layout = QVBoxLayout(self)
        layout.addWidget(label("Read-only SFTP browser · double-click a folder or file", "accent"))
        row = QHBoxLayout()
        self.path = QLineEdit(path)
        self.path.returnPressed.connect(self.browse)
        row.addWidget(button("Up", self.up))
        row.addWidget(self.path, 1)
        self.go = button("Open", self.browse)
        row.addWidget(self.go)
        layout.addLayout(row)
        self.columns = [("Name", "name"), ("Kind", "kind"), ("Bytes", "bytes"), ("Modified", "modified")]
        self.listing = table(self.columns)
        self.listing.cellDoubleClicked.connect(self.open_entry)
        layout.addWidget(self.listing, 1)
        self.message = label("", "muted", True)
        layout.addWidget(self.message)
        self.preview = QPlainTextEdit()
        self.preview.setReadOnly(True)
        self.preview.setPlaceholderText("Select a text file to preview its first 128 KiB.")
        layout.addWidget(self.preview, 1)
        self.browse()

    def up(self):
        self.path.setText(posixpath.dirname(self.path.text()) or "/")
        self.browse()

    def browse(self):
        path = self.path.text()
        self.go.setEnabled(False)
        self.listing.setEnabled(False)
        self.message.setText("Reading directory…")
        if self.owner.is_demo:
            self.listed(
                (
                    path,
                    [
                        {
                            "name": "train.log",
                            "bytes": 1024,
                            "directory": False,
                            "modified": 0,
                            "symlink": False,
                        }
                    ],
                ),
                None,
            )
            return
        session = self.owner.manager.sessions.get(self.profile.id)
        if not session or not session.connected:
            self.listed(None, ValueError("Connect this cluster first."))
            return
        self.owner.submit(lambda: session.files(path), self.listed)

    def listed(self, value, error):
        self.go.setEnabled(True)
        self.listing.setEnabled(True)
        if error:
            self.message.setText(str(error))
            return
        path, self.entries = value
        self.path.setText(path)
        rows = [
            {
                **f,
                "kind": "Link" if f["symlink"] else "Folder" if f["directory"] else "File",
                "modified": datetime.fromtimestamp(f["modified"]).strftime("%d %b %Y %H:%M")
                if f["modified"]
                else "—",
            }
            for f in self.entries
        ]
        fill_table(self.listing, self.columns, rows)
        self.message.setText(f"{len(rows)} entries · no upload, rename or delete operations")

    def open_entry(self, row, col):
        item = self.listing.item(row, 0)
        if item is None:
            return
        data = item.data(Qt.ItemDataRole.UserRole)
        path = posixpath.join(self.path.text(), data["name"])
        if data["directory"]:
            self.path.setText(path)
            self.browse()
        elif self.owner.is_demo:
            self.preview.setPlainText("DEMO DATA\nEpoch 1 · loss 0.42\nEpoch 2 · loss 0.37")
        else:
            session = self.owner.manager.sessions.get(self.profile.id)
            if session and session.connected:
                self.owner.submit(lambda: session.preview(path), self.previewed)

    def previewed(self, value, error):
        self.preview.setPlainText(str(error) if error else value)


class MainWindow(QMainWindow):
    def __init__(self, store=None, is_demo=False):
        super().__init__()
        self.store = store or LocalStore()
        self.is_demo = is_demo
        self.snapshots, self.history, self.states, self.errors = {}, {}, {}, {}
        # Job changes for the banner where no tray can show them (notify_jobs).
        self.job_notices = {}
        # When to collect storage and how its rows merge, per cluster.
        self.storage = {p.id: StorageTracker() for p in PROFILES}
        self.busy, self.tasks = set(), set()
        self.connecting = False
        self.closing = False
        self.account = ""
        self.pool = QThreadPool(self)
        self.pool.setMaxThreadCount(6)
        self.bridge = PromptBridge(self)
        self.manager = ConnectionManager(
            HostVerifier(self.store.root / KNOWN_HOSTS_FILE, self.bridge.ask), self.bridge.ask
        )
        self.setWindowTitle(
            "Leeds HPC Monitor" + (" · DEMO — synthetic data" if is_demo else f" · {PLATFORM.name}")
        )
        self.resize(1280, 840)
        self.setMinimumSize(1050, 740)
        self.setWindowIcon(self.make_icon())
        self.build_ui()
        self.setup_tray()
        prefs = self.store.read(SETTINGS_FILE, {})
        if isinstance(prefs, dict):
            self.username.setText(
                prefs.get("username", "") if isinstance(prefs.get("username", ""), str) else ""
            )
            self.route.setCurrentIndex(1 if prefs.get("route") == "jump" else 0)
        if is_demo:
            self.username.setText("demo")
            self.account = "demo"
            self.snapshots = demo.snapshots()
            self.history = {p.id: demo.history(i) for i, p in enumerate(PROFILES)}
            self.states = {p.id: "DEMO / SYNTHETIC" for p in PROFILES}
            self.connect_button.setEnabled(False)
            self.username.setEnabled(False)
            self.password.setEnabled(False)
            self.route.setEnabled(False)
        else:
            self.load_account()
        self.username.editingFinished.connect(self.load_account)
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.tick)
        self.timer.start(1000)
        self.ticks = 0
        self.render()

    def make_icon(self):
        pixmap = QPixmap(64, 64)
        pixmap.fill(QColor("#137e65"))
        painter = QPainter(pixmap)
        painter.setPen(QPen(QColor("white"), 5))
        painter.drawLine(14, 46, 14, 17)
        painter.drawLine(14, 46, 48, 46)
        painter.drawLine(28, 35, 28, 21)
        painter.drawLine(42, 35, 42, 12)
        painter.end()
        return QIcon(pixmap)

    def build_ui(self):
        root = QWidget()
        self.setCentralWidget(root)
        horizontal = QHBoxLayout(root)
        horizontal.setContentsMargins(0, 0, 0, 0)
        horizontal.setSpacing(0)
        sidebar = QFrame()
        sidebar.setObjectName("sidebar")
        sidebar.setFixedWidth(255)
        side = QVBoxLayout(sidebar)
        side.setContentsMargins(20, 26, 20, 20)
        side.addWidget(label("LEEDS / RESEARCH COMPUTING", "accent"))
        side.addWidget(label("HPC Monitor", "brand"))
        side.addWidget(label(f"{PLATFORM.name} · independent project", "muted"))
        side.addSpacing(20)
        self.nav = QListWidget()
        self.nav.addItems(["Overview", "Jobs", "Partitions", "Nodes", "Storage", "Trends", "Files & logs"])
        self.nav.setCurrentRow(0)
        self.nav.currentRowChanged.connect(self.navigate)
        side.addWidget(self.nav, 1)
        side.addWidget(label("CONNECTION", "accent"))
        self.username = QLineEdit()
        self.username.setPlaceholderText("University username")
        self.username.setAccessibleName("University username")
        self.password = QLineEdit()
        self.password.setPlaceholderText("Password (or saved credential)")
        self.password.setEchoMode(QLineEdit.EchoMode.Password)
        self.password.setAccessibleName("University password")
        self.password.returnPressed.connect(self.connect_all)
        self.route = QComboBox()
        self.route.addItem("Direct (VPN / campus)", "direct")
        self.route.addItem("Via rash jump host", "jump")
        side.addWidget(self.username)
        side.addWidget(self.password)
        side.addWidget(self.route)
        choices = QHBoxLayout()
        self.enabled = {}
        for p in PROFILES:
            choice = QCheckBox(p.name)
            choice.setChecked(True)
            self.enabled[p.id] = choice
            choices.addWidget(choice)
        side.addLayout(choices)
        self.remember = QCheckBox(PLATFORM.remember_label)
        side.addWidget(self.remember)
        self.connect_button = button("Connect selected", self.connect_all, True)
        side.addWidget(self.connect_button)
        self.disconnect_button = button("Disconnect", self.disconnect)
        side.addWidget(self.disconnect_button)
        side.addWidget(button("Forget saved password", self.forget_password))
        side.addSpacing(10)
        side.addWidget(label("Read-only remote access.\nNo jobs or files are changed.", "muted", True))
        horizontal.addWidget(sidebar)
        body = QVBoxLayout()
        body.setContentsMargins(30, 26, 30, 20)
        body.setSpacing(16)
        heading = QHBoxLayout()
        self.title = label("Overview", "title")
        heading.addWidget(self.title, 1)
        self.cluster_filter = QComboBox()
        self.cluster_filter.addItem("All clusters", "all")
        for p in PROFILES:
            self.cluster_filter.addItem(p.name, p.id)
        self.cluster_filter.currentIndexChanged.connect(self.render)
        heading.addWidget(self.cluster_filter)
        heading.addWidget(button("Refresh now", self.refresh_now))
        # Relabelled "Minimize" by setup_tray when there is no tray to hide into.
        self.minimize_button = button("Minimize to tray", self.minimize)
        heading.addWidget(self.minimize_button)
        body.addLayout(heading)
        self.banner = label("", "banner", True)
        body.addWidget(self.banner)
        self.stack = QStackedWidget()
        self.overview = QWidget()
        self.overview_layout = QVBoxLayout(self.overview)
        self.overview_layout.setContentsMargins(0, 0, 0, 0)
        self.cards = {}
        for p in PROFILES:
            card = QFrame()
            card.setObjectName("card")
            layout = QVBoxLayout(card)
            layout.setContentsMargins(22, 18, 22, 20)
            # Renamed by render_cards to the GPU models the snapshot reports.
            name = label(p.name, "brand")
            name.setStyleSheet(f"color: {p.color}")
            layout.addWidget(name)
            state, summary, details = label(""), label("", wrap=True), label("", "muted", True)
            summary.setStyleSheet("font-size: 23px; font-weight: 600;")
            layout.addWidget(state)
            layout.addSpacing(8)
            layout.addWidget(summary)
            layout.addWidget(details)
            self.cards[p.id] = (card, name, state, summary, details)
            self.overview_layout.addWidget(card)
        self.overview_layout.addWidget(
            label(
                "Idle GPUs are ones a new job could start on now: on nodes that accept work (not down, "
                "drained, draining, reserved, rebooting or not responding) with a CPU free. Each GPU model "
                "is counted on its own; 'stranded' GPUs are idle on nodes whose CPUs are all taken.\n"
                "Capacity is not a scheduling guarantee. Home quota is shared by both clusters.",
                "muted",
                True,
            )
        )
        self.overview_layout.addStretch()
        self.stack.addWidget(self.overview)
        self.columns = {
            # The display_fields functions in core add the derived columns.
            "jobs": [
                ("Cluster", "cluster"),
                # "123_[2-9]" for an array's pending remainder: the bare id
                # would read as one job (and stands for the whole array).
                ("Job ID", "display_id"),
                ("Name", "name"),
                ("State", "state_label"),
                ("Jobs", "jobs"),
                ("Partition", "partition"),
                ("Elapsed", "elapsed"),
                ("Limit", "time_limit"),
                ("Nodes / reason", "reason_or_node_list"),
            ],
            "partitions": [
                ("Cluster", "cluster"),
                ("Partition", "partition"),
                ("Availability", "availability"),
                ("Nodes", "node_count"),
                ("State", "state_label"),
                ("Slurm state", "state"),
                ("GPUs / node", "gres"),
                ("CPUs / node", "cpus_per_node"),
                ("Walltime", "time_limit"),
            ],
            "nodes": [
                ("Cluster", "cluster"),
                ("Node", "node"),
                ("State", "state_label"),
                ("Accepts work", "accepts_work"),
                ("Partitions", "partitions"),
                ("GPU model", "gpu_model"),
                ("GPUs", "gpu_count"),
                ("GPUs unallocated", "gpu_unallocated"),
                ("GPUs startable", "gpu_startable"),
                ("CPUs idle", "cpu_idle"),
                ("RAM MiB", "memory_mb"),
                ("Slurm state", "state"),
                ("Reason", "reason"),
            ],
            "storage": [
                ("Cluster", "cluster"),
                ("Volume", "label"),
                ("Status", "status"),
                ("Pressure %", "pressure_percent"),
                ("Path", "path"),
                ("Used GiB", "used_gb"),
                ("Quota GiB", "quota_gb"),
                ("Hard limit GiB", "limit_gb"),
                ("Available GiB", "available_gb"),
                ("Used %", "used_percent"),
                ("Files", "file_count"),
                ("File quota", "file_quota"),
                ("File limit", "file_limit"),
                ("Over quota", "over_quota_text"),
                ("Source", "source"),
                ("Quota type", "quota_type"),
                ("Unavailable reason", "unavailable_reason"),
            ],
        }
        self.row_fields = {
            "jobs": job_display_fields,
            "partitions": partition_display_fields,
            "nodes": node_display_fields,
            "storage": storage_display_fields,
        }
        self.tables = {}
        for section, columns in self.columns.items():
            page = QWidget()
            layout = QVBoxLayout(page)
            layout.setContentsMargins(0, 0, 0, 0)
            self.tables[section] = table(columns)
            layout.addWidget(self.tables[section])
            if section == "jobs":
                layout.addWidget(label("Double-click a job for its details and output log.", "muted"))
                self.tables[section].cellDoubleClicked.connect(self.job_details)
            if section == "storage":
                # Filled in by render: when each cluster's rows were collected.
                self.storage_note = label("", "muted", True)
                layout.addWidget(self.storage_note)
            self.stack.addWidget(page)
        trends_page = QWidget()
        trend_layout = QVBoxLayout(trends_page)
        trend_layout.setContentsMargins(0, 0, 0, 0)
        trend_layout.addWidget(label("Idle GPUs over time", "brand"))
        # Filled in by render with the colours and the models seen.
        self.trend_legend = label("", "muted", True)
        trend_layout.addWidget(self.trend_legend)
        self.plot = TrendPlot()
        trend_layout.addWidget(self.plot, 1)
        self.history_columns = [
            ("Cluster", "cluster"),
            ("Time (local)", "time"),
            ("Idle GPUs (all models)", "gpu_idle"),
            ("Idle CPUs (CPU nodes)", "cpu_idle"),
            ("Running", "running"),
            ("Pending", "pending"),
            ("Held", "held"),
            ("Nodes accepting no work", "unavailable"),
        ]
        self.history_table = table(self.history_columns)
        trend_layout.addWidget(self.history_table, 1)
        self.stack.addWidget(trends_page)
        files_page = QWidget()
        files_layout = QVBoxLayout(files_page)
        files_layout.addWidget(label("Browse without changing anything", "brand"))
        files_layout.addWidget(
            label(
                "Read folders and bounded text previews over the existing SSH session.\n"
                "For job output, double-click a job on the Jobs page.",
                "muted",
                True,
            )
        )
        for p in PROFILES:
            files_layout.addWidget(
                button(f"Browse {p.name} files", lambda checked=False, p=p: self.open_files(p))
            )
        files_layout.addStretch()
        self.stack.addWidget(files_page)
        body.addWidget(self.stack, 1)
        self.status = label("", "muted", True)
        body.addWidget(self.status)
        horizontal.addLayout(body, 1)

    def setup_tray(self):
        # Without a tray host (stock GNOME without the AppIndicator extension,
        # some tiling window managers) the icon never appears: a window hidden
        # into it could not be restored or quit, and its SSH sessions would
        # stay open until the process was killed. So no tray, no hiding.
        self.tray: QSystemTrayIcon | None = None
        if not platform_support.tray_available():
            self.minimize_button.setText("Minimize")
            return
        self.tray = QSystemTrayIcon(self.windowIcon(), self)
        menu = QMenu(self)
        for text, action in (
            ("Show monitor", self.restore),
            ("Refresh", self.refresh_now),
            ("Quit", self.close),
        ):
            item = QAction(text, self)
            item.triggered.connect(action)
            menu.addAction(item)
        self.tray.setContextMenu(menu)
        self.tray.activated.connect(
            lambda reason: self.restore() if reason == QSystemTrayIcon.ActivationReason.Trigger else None
        )
        self.tray.show()

    def minimize(self):
        if self.tray is not None:
            self.hide()
        else:
            self.showMinimized()

    def restore(self):
        self.showNormal()
        self.raise_()
        self.activateWindow()

    def submit(self, function, callback):
        def finished(value, error):
            if not self.closing:
                callback(value, error)

        task = Task(function, finished)
        self.tasks.add(task)
        task.signals.done.connect(lambda value, error: self.tasks.discard(task))
        self.pool.start(task)

    def load_account(self):
        if self.is_demo or self.connecting or self.manager.sessions:
            return
        try:
            username = validate_username(self.username.text())
        except ValueError:
            username = ""
        if self.account == username:
            return
        self.account = username
        self.snapshots, self.history, self.states, self.errors = {}, {}, {}, {}
        self.job_notices = {}
        # Storage is per account: start the bookkeeping afresh, remembering
        # which volumes the cached rows had figures for.
        self.storage = {p.id: StorageTracker() for p in PROFILES}
        if username:
            for p in PROFILES:
                snapshot, history = self.store.load(username, p.id)
                if snapshot and not snapshot["errors"]:
                    self.snapshots[p.id], self.history[p.id] = snapshot, history
                    self.states[p.id] = "CACHED / OFFLINE"
                    self.storage[p.id].note_cached(snapshot)
        self.render()

    def vault(self):
        return platform_support.credential_backend()

    def saved_password(self, username):
        """Returns (password, problem): the saved password or None, and why
        it could not be read or None.

        A missing entry is simply None. A store that fails (a locked or
        absent Secret Service, a Credential Manager error) is reported the
        same way on both platforms, so the user knows why the password is
        asked for instead of seeing a raw error or nothing at all.
        """
        try:
            return self.vault().get_password(platform_support.CREDENTIAL_SERVICE, username), None
        except Exception as exc:
            return None, f"The saved password could not be read ({exc})."

    def forget_password(self):
        try:
            username = validate_username(self.username.text())
            vault = self.vault()
            if vault.get_password(platform_support.CREDENTIAL_SERVICE, username) is not None:
                vault.delete_password(platform_support.CREDENTIAL_SERVICE, username)
            self.password.clear()
            self.status.setText(PLATFORM.forgot_message)
        except Exception as exc:
            self.problem(str(exc))

    def problem(self, message):
        box = QMessageBox(self)
        box.setWindowTitle("Leeds HPC Monitor")
        box.setTextFormat(Qt.TextFormat.PlainText)
        box.setText(message)
        box.exec()

    def connect_all(self):
        if self.is_demo or self.connecting or self.busy:
            return
        try:
            username = validate_username(self.username.text())
            self.load_account()
            password, unreadable = self.password.text(), None
            if not password:
                password, unreadable = self.saved_password(username)
            if not password:
                raise ValueError(
                    (f"{unreadable} " if unreadable else "")
                    + "Enter your university password. It is never written to a file."
                )
            selected = [p for p in PROFILES if self.enabled[p.id].isChecked()]
            if not selected:
                raise ValueError("Select at least one cluster.")
        except Exception as exc:
            self.problem(str(exc))
            return
        route = self.route.currentData()
        remember = self.remember.isChecked()
        self.password.clear()
        try:
            self.store.write(SETTINGS_FILE, {"username": username, "route": route})
        except OSError as exc:
            self.problem(f"Could not save settings: {exc}")
            return
        self.set_connecting(True)
        for p in selected:
            self.states[p.id] = "SIGNING IN / approve Duo when prompted"
            self.errors.pop(p.id, None)
            # The first refresh after sign-in collects storage: the sign-in's
            # own collection always does, and if that one fails the next
            # timer refresh still asks for it.
            self.storage[p.id].due = True
        self.render()

        def connect():
            results = []
            for p in selected:
                try:
                    session = self.manager.connect(p, username, password, route)
                    # The first refresh after sign-in always collects storage.
                    results.append((p.id, session.collect(username), None))
                except (AuthenticationRejected, Cancelled) as exc:
                    results.append((p.id, None, exc))
                    break
                except Exception as exc:
                    results.append((p.id, None, exc))
            if remember and any(value is not None for _, value, _ in results):
                try:
                    self.vault().set_password(platform_support.CREDENTIAL_SERVICE, username, password)
                except Exception:
                    results.append(
                        (
                            "credential",
                            None,
                            RuntimeError(PLATFORM.save_failed_message),
                        )
                    )
            return results

        self.submit(connect, self.connected)

    def set_connecting(self, connecting):
        self.connecting = connecting
        self.connect_button.setEnabled(not connecting and not self.is_demo)
        self.disconnect_button.setEnabled(not connecting)
        self.username.setEnabled(not connecting and not self.manager.sessions and not self.is_demo)
        self.route.setEnabled(not connecting and not self.manager.sessions and not self.is_demo)

    def connected(self, value, error):
        self.set_connecting(False)
        if error:
            self.problem(str(error))
        else:
            for cluster, snapshot, issue in value:
                if cluster == "credential":
                    self.problem(str(issue))
                else:
                    self.receive(cluster, snapshot, issue)
        for p in PROFILES:
            if self.states.get(p.id, "").startswith("SIGNING"):
                self.states[p.id] = "SIGN-IN CANCELLED"
        self.render()

    def disconnect(self):
        if self.connecting or self.busy:
            self.status.setText("Wait for the current operation to finish before disconnecting.")
            return
        self.manager.disconnect()
        for p in PROFILES:
            self.states[p.id] = "CACHED / OFFLINE" if p.id in self.snapshots else "DISCONNECTED"
        self.set_connecting(False)
        self.render()

    def refresh_now(self):
        """Refresh now (button and tray): a manual refresh also collects storage."""
        self.refresh_all(manual=True)

    def refresh_all(self, manual=False):
        if self.is_demo or self.connecting:
            return
        now = time.monotonic()
        for p in PROFILES:
            session = self.manager.sessions.get(p.id)
            if session and session.connected and p.id not in self.busy:
                self.busy.add(p.id)
                # Storage (df, quota, lfs on shared filesystems) only when
                # due: after sign-in, on Refresh now, or every 5 minutes.
                # Other refreshes skip it and keep the previous rows.
                want = self.storage[p.id].wants_storage(manual, now)
                self.submit(
                    lambda session=session, want=want: session.collect(self.account, skip_storage=not want),
                    lambda value, error, cluster=p.id, want=want: self.receive(
                        cluster, value, error, requested_storage=want
                    ),
                )

    def receive(self, cluster, value, error, requested_storage=True):
        self.busy.discard(cluster)
        if error or (value and value.get("errors")):
            self.errors[cluster] = str(error) if error else "; ".join(value["errors"])
            self.states[cluster] = "STALE / REFRESH FAILED"
        elif value:
            try:
                validate_snapshot(value, cluster, self.account)
                old = self.snapshots.get(cluster)
                # Storage that was not collected (None) keeps the rows on
                # screen, rows cut short keep their figures for a while, and
                # the merged snapshot is what is shown, cached and charted.
                value = self.storage[cluster].receive(old, value, requested_storage, time.monotonic())
                self.snapshots[cluster] = value
                history = self.history.setdefault(cluster, [])
                history.append(history_point(value))
                del history[:-8640]
                self.states[cluster] = "CONNECTED"
                self.errors.pop(cluster, None)
                if not self.is_demo:
                    self.store.save(self.account, cluster, value, history)
                    if old:
                        self.notify_jobs(cluster, old, value)
            except ValueError as exc:
                self.states[cluster] = "STALE / INVALID SNAPSHOT"
                self.errors[cluster] = str(exc)
            except OSError as exc:
                self.errors[cluster] = str(exc)
        self.render()

    def notify_jobs(self, cluster, old, new):
        # Starts and endings as the macOS app reports them: an array's
        # pending remainder vanishing because its last task started is not
        # "left the queue", and its newly running tasks count as starts.
        changes = job_change_messages(old["jobs"], new["jobs"])
        if self.tray is not None and QSystemTrayIcon.supportsMessages():
            if changes:
                self.tray.showMessage(
                    f"{cluster.upper()} jobs", "\n".join(changes[:4]), QSystemTrayIcon.MessageIcon.Information
                )
        elif changes:
            # No tray to notify through: show the latest refresh's changes in
            # the banner instead of dropping them silently.
            self.job_notices[cluster] = "; ".join(changes[:4])
        else:
            self.job_notices.pop(cluster, None)

    def tick(self):
        self.ticks += 1
        lost = False
        for p in PROFILES:
            session = self.manager.sessions.get(p.id)
            if self.states.get(p.id) == "CONNECTED" and (not session or not session.connected):
                self.states[p.id] = "STALE / CONNECTION LOST"
                lost = True
        if lost:
            self.render()
        if self.ticks % 10 == 0:
            self.refresh_all()
        # Do not rebuild tables every second; preserve selection and scroll position.
        if self.nav.currentRow() == 0:
            self.render_cards()

    def profiles(self):
        return [p for p in PROFILES if self.cluster_filter.currentData() in ("all", p.id)]

    def navigate(self, index):
        if hasattr(self, "stack"):
            self.stack.setCurrentIndex(index)
            self.title.setText(self.nav.item(index).text())
            self.render()

    def render_cards(self):
        for p in PROFILES:
            card, name, state, summary, details = self.cards[p.id]
            card.setVisible(p in self.profiles())
            snapshot = self.snapshots.get(p.id)
            age = ""
            if snapshot:
                stamp = datetime.fromisoformat(snapshot["collected_at"])
                if stamp.tzinfo is None:
                    stamp = stamp.replace(tzinfo=timezone.utc)
                seconds = max(0, int((datetime.now(timezone.utc) - stamp).total_seconds()))
                age = f" · snapshot {seconds // 60}m {seconds % 60}s ago"
            session = self.manager.sessions.get(p.id)
            status = self.states.get(p.id, "NOT CONNECTED")
            if status == "CONNECTED" and (not session or not session.connected):
                status = "STALE / CONNECTION LOST"
            state.setText(status + age)
            if snapshot:
                # The macOS overview's figures: jobs by queue state (held
                # apart, array tasks counted one by one), idle GPUs per
                # model (largest pool first, never summed across models),
                # CPUs on CPU-only nodes, and storage with its pressure.
                figures = cluster_figures(snapshot)
                name.setText(card_heading(p, figures.fleet))
                summary.setText(card_summary(figures))
                details.setText(
                    "\n".join([*pool_lines(figures.fleet), cpu_summary(figures), storage_summary(snapshot)])
                )
            else:
                name.setText(p.name)
                summary.setText("No snapshot yet")
                details.setText(
                    f"{p.host}\nConnect on VPN or use the rash jump host. Nothing is contacted until you connect."
                )

    def render(self, *args):
        if not hasattr(self, "cards"):
            return
        self.render_cards()
        selected = self.profiles()
        notices = []
        if self.is_demo:
            notices.append("DEMO — synthetic data. No SSH connections are made and no examples are cached.")
        for p in selected:
            if p.id in self.snapshots and self.states.get(p.id) != "CONNECTED" and not self.is_demo:
                notices.append(f"{p.name}: showing a saved snapshot, not live data.")
            if p.id in self.errors:
                notices.append(f"{p.name}: {self.errors[p.id]}")
            snapshot = self.snapshots.get(p.id)
            if snapshot:
                notices.extend(f"{p.name}: {warning}" for warning in snapshot.get("warnings", []))
            if p.id in self.job_notices:
                notices.append(f"{p.name} jobs: {self.job_notices[p.id]}")
        self.banner.setVisible(bool(notices))
        self.banner.setText("\n".join(notices))
        statuses = "  |  ".join(f"{p.name}: {self.states.get(p.id, 'not connected')}" for p in selected)
        self.status.setText(
            statuses
            + " · jobs, GPUs and nodes every 10 s, storage every 5 min · sessions end when the app quits"
        )
        if self.tray is not None:
            self.tray.setToolTip("Leeds HPC Monitor\n" + statuses[:1000])
        for section, columns in self.columns.items():
            rows = []
            for p in selected:
                # storage is None until it has been collected once.
                section_rows = self.snapshots.get(p.id, {}).get(section) or []
                if section == "jobs":
                    section_rows = sorted(section_rows, key=job_sort_key)
                rows += [
                    {**row, **self.row_fields[section](row), "cluster": p.name, "cluster_id": p.id}
                    for row in section_rows
                ]
            fill_table(self.tables[section], columns, rows)
        self.storage_note.setText(self.storage_note_text(selected))
        self.trend_legend.setText(self.trend_legend_text(selected))
        self.plot.set_series([(p, self.history.get(p.id, [])) for p in selected])
        rows = [
            {
                **row,
                "cluster": p.name,
                "time": local_time_text(row.get("time"), "%d %b %H:%M:%S"),
                "gpu_idle": history_gpu_text(row),
            }
            for p in selected
            for row in self.history.get(p.id, [])[-100:]
        ]
        fill_table(self.history_table, self.history_columns, rows)

    def trend_legend_text(self, selected):
        # Each line is one cluster's startable idle GPUs with every model
        # added together (the one place models are summed, as on the Mac),
        # so the legend names the models instead of a fixed one.
        lines = []
        for p in selected:
            models = gpu_fleet(self.snapshots.get(p.id, {})).model_label
            lines.append(f"{p.name} = {p.color_name}" + (f" ({models})" if models else ""))
        return (
            "   ".join(lines)
            + " · startable idle GPUs, every model of a cluster together (the Overview names each model)"
            + " · local time"
        )

    def storage_note_text(self, selected):
        times = []
        for p in selected:
            stamp = storage_rows_time(self.snapshots.get(p.id))
            if stamp:
                times.append(f"{p.name} rows from {local_time_text(stamp, '%d %b %H:%M:%S')}")
        return (
            "Home is shared across clusters. ‘df’ means filesystem-wide totals, not your personal quota. "
            "Status turns Warning at 75 % and Critical at 90 % of space or files, whichever is fuller, "
            "and Over quota once a soft quota is exceeded.\n"
            "Storage is collected after sign-in, on Refresh now and every 5 minutes"
            + (f" ({', '.join(times)}, local time)." if times else ".")
        )

    def open_files(self, profile, path="."):
        session = self.manager.sessions.get(profile.id)
        if not self.is_demo and (not session or not session.connected):
            self.problem(f"Connect to {profile.name} first.")
            return
        dialog = FileBrowser(self, profile, path)
        dialog.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose, False)
        dialog.exec()

    def job_details(self, row, column):
        item = self.tables["jobs"].item(row, 0)
        if not item:
            return
        job = item.data(Qt.ItemDataRole.UserRole)
        profile = next(p for p in PROFILES if p.id == job["cluster_id"])
        dialog = QDialog(self)
        dialog.setWindowTitle(f"{profile.name} · job {job.get('display_id') or job['job_id']}")
        dialog.resize(820, 650)
        layout = QVBoxLayout(dialog)
        # Slurm's submit/start/end times are cluster (UK) wall-clock times
        # without a zone; job_details_text shows them in local time, labelled.
        detail = QPlainTextEdit(job_details_text(job))
        detail.setReadOnly(True)
        layout.addWidget(detail)
        output = QPlainTextEdit()
        output.setReadOnly(True)
        output.setPlaceholderText(
            "Read the latest 128 KiB of the job's stdout file. No shell commands are evaluated."
        )
        layout.addWidget(output)

        def read_log():
            if self.is_demo:
                output.setPlainText("DEMO DATA\nEpoch 1 · loss 0.42\nEpoch 2 · loss 0.37")
                return
            session = self.manager.sessions.get(profile.id)
            path = job.get("stdout_path")
            if not session or not session.connected or not path:
                output.setPlainText("Connect this cluster and select a job with an output path.")
                return
            if "%" in path:
                output.setPlainText(
                    "Slurm output path contains an unresolved placeholder. Browse its working directory to select the actual log."
                )
                return
            self.submit(
                lambda: session.preview(path, tail=True),
                lambda value, error, keep_alive=dialog: output.setPlainText(str(error) if error else value),
            )

        layout.addWidget(button("Refresh output tail", read_log))
        layout.addWidget(
            button("Browse working directory", lambda: self.open_files(profile, job.get("work_dir") or "."))
        )
        dialog.exec()

    def closeEvent(self, event):
        self.closing = True
        self.timer.stop()
        self.bridge.close()
        self.manager.stop()
        if self.tray is not None:
            self.tray.hide()
        event.accept()


def main():
    parser = argparse.ArgumentParser(description=f"Leeds HPC Monitor for {PLATFORM.name}")
    parser.add_argument(
        "--demo", action="store_true", help="Synthetic offline data; makes no network connections"
    )
    parser.add_argument("--smoke-test", action="store_true", help="Check packaged startup offline, then exit")
    args = parser.parse_args()
    app = QApplication(sys.argv[:1])
    app.setApplicationName("Leeds HPC Monitor")
    app.setOrganizationName("LeedsHPCMonitor")
    app.setStyle("Fusion")
    app.setStyleSheet(STYLE)
    app.setQuitOnLastWindowClosed(True)
    # The platform's data folder, or LEEDS_HPC_DATA_DIR (platform_support.data_dir).
    store = LocalStore()
    window = MainWindow(store, args.demo or args.smoke_test)
    window.show()
    if args.smoke_test:
        assert window.tables["jobs"].rowCount() == 4
        # Fails the frozen build when the credential store's modules were not bundled.
        platform_support.smoke_check()
        for index in range(window.stack.count()):
            window.nav.setCurrentRow(index)
        window.nav.setCurrentRow(0)
        QTimer.singleShot(500, window.close)
    result = app.exec()
    window.bridge.close()
    window.manager.stopping.set()
    window.pool.waitForDone()
    window.manager.disconnect()
    return result
