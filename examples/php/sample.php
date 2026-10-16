<?php
// sample.php - ZONU inzm (PHP nano-style editor) demo!

echo "🐘 Welcome to ZONU inzm editor in PHP!\n";
echo "Date: " . date('Y-m-d H:i:s') . "\n";

$features = [
    "Nano 3-tier layout (Titlebar, Edit Area, Statusline, 2-line Shortcut Bar)",
    "DSR probe automatic EAW detection (East Asian Ambiguous Width)",
    "Cut & Paste lines (^K / ^U)",
    "Instant script execution (^T)",
    "WriteOut (^O) and Exit (^X) with modified buffer prompt",
];

foreach ($features as $i => $feat) {
    echo " [" . ($i + 1) . "] {$feat}\n";
}

// Press ^T (Ctrl+T) to execute this PHP script!
// Press ^O (Ctrl+O) to save!
// Press ^X (Ctrl+X) to exit!
