<?php
// sample.php - PHP inzm editor demo!

echo "🐘 Welcome to inzm editor in PHP!\n";
echo "Date: " . date('Y-m-d H:i:s') . "\n";

$languages = ["PHP", "Ruby", "TypeScript/Bun", "Go"];
foreach ($languages as $i => $lang) {
    echo " [" . ($i + 1) . "] {$lang}\n";
}

// Press Ctrl+R to run this script instantly!
