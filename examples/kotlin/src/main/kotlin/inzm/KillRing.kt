package inzm

/**
 * Emacs / jEdit 互換の循環キルリング (Kill Ring)。
 *
 * - 連続したキル操作 (lastActionWasKill == true) は新規エントリを追加せず、先頭エントリに連結する。
 * - yank() (Ctrl+Y) で最新エントリを貼り付けた直後の yankPop() (Alt+Y) は、
 *   前回の貼り付けテキストをリング内の過去履歴で順次差し替える。
 */
class KillRing(val capacity: Int = 32) {
    private val entries = ArrayList<String>()

    var yankPointer: Int = 0
        private set

    var lastActionWasKill: Boolean = false
        private set

    var lastActionWasYank: Boolean = false
        private set

    data class YankSpan(
        val bufferIndex: Int,
        val startRow: Int,
        val startCol: Int,
        val endRow: Int,
        val endCol: Int,
    )

    var lastYankSpan: YankSpan? = null

    val size: Int
        get() = entries.size

    fun isEmpty(): Boolean = entries.isEmpty()

    fun snapshot(): List<String> = entries.toList()

    fun currentEntry(): String? = entries.getOrNull(yankPointer)

    /**
     * テキストをキルリングへ積む。
     * @param appendToCurrent true のとき、直前もキル操作なら末尾に連結する
     * @param prepend true のとき（後方削除など）、直前エントリの先頭に連結する
     */
    fun pushKill(text: String, appendToCurrent: Boolean = true, prepend: Boolean = false) {
        if (text.isEmpty()) return
        if (appendToCurrent && lastActionWasKill && entries.isNotEmpty()) {
            entries[0] = if (prepend) text + entries[0] else entries[0] + text
        } else {
            entries.add(0, text)
            if (entries.size > capacity) {
                entries.removeAt(entries.lastIndex)
            }
        }
        yankPointer = 0
        lastActionWasKill = true
        lastActionWasYank = false
        lastYankSpan = null
    }

    /**
     * テキストを削除せずコピーのみを行う (Alt+W 等)。
     * キル連結チェーンは切断する。
     */
    fun pushCopy(text: String) {
        if (text.isEmpty()) return
        entries.add(0, text)
        if (entries.size > capacity) {
            entries.removeAt(entries.lastIndex)
        }
        yankPointer = 0
        lastActionWasKill = false
        lastActionWasYank = false
        lastYankSpan = null
    }

    /**
     * 最新（現在の先頭）エントリを取得してヤンク状態に入る (Ctrl+Y)。
     */
    fun beginYank(): String? {
        if (entries.isEmpty()) return null
        yankPointer = 0
        lastActionWasKill = false
        lastActionWasYank = true
        return entries[yankPointer]
    }

    /**
     * 直前がヤンクまたは yankPop だった場合にリングを 1 つ過去へ回転させ、そのテキストを返す (Alt+Y)。
     * 末尾まで回ったら先頭 (0) へ戻る。直前がヤンクでない場合は null を返す。
     */
    fun yankPop(): String? {
        if (!lastActionWasYank || entries.isEmpty()) return null
        yankPointer = (yankPointer + 1) % entries.size
        lastActionWasKill = false
        lastActionWasYank = true
        return entries[yankPointer]
    }

    /**
     * Kill Ring 一覧から明示インデックスを選んで貼り付ける (Ctrl+E Ctrl+K)。
     */
    fun yankAt(index: Int): String? {
        if (index !in entries.indices) return null
        yankPointer = index
        lastActionWasKill = false
        lastActionWasYank = true
        return entries[index]
    }

    /**
     * 移動・通常入力・保存などの非キル／非ヤンク操作時にチェーンを切断する。
     */
    fun breakChain() {
        lastActionWasKill = false
        lastActionWasYank = false
        lastYankSpan = null
    }
}
