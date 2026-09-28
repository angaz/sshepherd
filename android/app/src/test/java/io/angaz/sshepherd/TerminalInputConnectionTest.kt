package io.angaz.sshepherd

import android.content.Context
import android.text.InputType
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class TerminalInputConnectionTest {
    private val text = mutableListOf<String>()
    private val keys = mutableListOf<KeyEvent>()
    private var remote = ""
    private var position = 0
    private var accept = true
    private val edits = mutableListOf<TerminalEdit>()
    private lateinit var input: TerminalInputConnection
    @Before fun setup() {
        val context: Context = RuntimeEnvironment.getApplication()
        input = TerminalInputConnection(View(context), { edit ->
            if (!accept) false else {
                edits.add(edit); text.add(edit.text)
                position = remote.offsetByCodePoints(position, edit.right)
                val start = remote.offsetByCodePoints(position, -edit.erase)
                remote = remote.substring(0, start) + edit.text + remote.substring(position)
                position = remote.offsetByCodePoints(start + edit.text.length, -edit.left)
                if (edit.extraBefore != 0) {
                    val end = remote.offsetByCodePoints(position, -edit.protectedPoints)
                    val from = remote.offsetByCodePoints(end, -minOf(edit.extraBefore, remote.codePointCount(0, end)))
                    remote = remote.removeRange(from, end)
                    position -= end - from
                }
                val end = remote.offsetByCodePoints(position, minOf(edit.extraAfter, remote.codePointCount(position, remote.length)))
                remote = remote.removeRange(position, end)
                true
            }
        }, { keys.add(it); true })
    }
    @Test fun normalTextEditorEnablesImeSuggestionsAndSwipeWithoutCapitalizationOrLearning() {
        val info = EditorInfo()
        configureTerminalEditor(info)
        assertEquals(InputType.TYPE_CLASS_TEXT, info.inputType and InputType.TYPE_MASK_CLASS)
        assertEquals(InputType.TYPE_TEXT_VARIATION_NORMAL, info.inputType and InputType.TYPE_MASK_VARIATION)
        assertTrue(info.inputType and InputType.TYPE_TEXT_FLAG_AUTO_CORRECT != 0)
        assertEquals(0, info.inputType and (InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS or InputType.TYPE_TEXT_FLAG_AUTO_COMPLETE))
        assertEquals(0, info.inputType and (InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS or InputType.TYPE_TEXT_FLAG_CAP_WORDS or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES))
        assertEquals(0, info.initialCapsMode)
        assertTrue(info.imeOptions and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING != 0)
    }
    @Test fun swipeCandidatesAndSuggestedReplacementOnlySubmitFinalWordsOnce() {
        input.setComposingText("helo", 1)
        input.setComposingText("hello", 1)
        assertTrue(text.isEmpty())
        input.commitText("hello", 1)
        input.finishComposingText()
        input.commitText(" ", 1)
        input.setComposingText("wrld", 1)
        input.commitText("world", 1)
        input.finishComposingText()
        assertEquals(listOf("hello", " ", "world"), text)
        assertTrue(keys.isEmpty())
    }
    @Test fun unicodeCommitAndBackspaceWithoutHardwareEvents() {
        assertTrue(input.commitText("héllo 🐑", 1))
        assertEquals(listOf("héllo 🐑"), text)
        assertTrue(input.deleteSurroundingTextInCodePoints(1, 0))
        assertEquals("héllo ", remote)
        assertEquals(1, edits.last().erase)
        input.discardComposition()
        input.deleteSurroundingText(2, 1)
        assertEquals(2, edits.last().extraBefore)
        assertEquals(1, edits.last().extraAfter)
    }
    @Test fun compositionReplacementCommitsOnce() {
        input.setComposingText("に", 1)
        input.setComposingText("日本", 1)
        assertTrue(text.isEmpty())
        input.commitText("日本", 1)
        input.finishComposingText()
        assertEquals(listOf("日本"), text)
        assertEquals("日本", input.editable.toString())
    }
    @Test fun finishingCompositionCommitsButDiscardDoesNot() {
        input.setComposingText("draft", 1)
        input.finishComposingText()
        input.finishComposingText()
        assertEquals(listOf("draft"), text)
        input.setComposingText("abandoned", 1)
        input.discardComposition()
        input.finishComposingText()
        assertEquals(listOf("draft"), text)
    }
    @Test fun composingDeletionNeverSendsRemoteBackspace() {
        input.setComposingText("test", 1)
        input.deleteSurroundingText(1, 0)
        assertTrue(keys.isEmpty())
    }
    @Test fun imeEnterAndKeyEventsAreForwardedOnce() {
        input.performEditorAction(EditorInfo.IME_ACTION_DONE)
        input.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_A))
        assertEquals(listOf(KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_A), keys.map { it.keyCode })
    }
    @Test fun imeEnterCommitsCompositionBeforeKeyPressExactlyOnce() {
        val ordered = mutableListOf<String>()
        val connection = TerminalInputConnection(View(RuntimeEnvironment.getApplication()), { ordered.add(it.text); true }, { ordered.add("key:${it.keyCode}:${it.action}"); true })
        connection.setComposingText("echo hello", 1)
        connection.performEditorAction(EditorInfo.IME_ACTION_DONE)
        connection.finishComposingText()
        assertEquals(listOf("echo hello", "key:66:0", "key:66:1"), ordered)
        ordered.clear()
        connection.setComposingText("next", 1)
        connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
        connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
        connection.finishComposingText()
        assertEquals(listOf("next", "key:66:0", "key:66:1"), ordered)
    }
    @Test fun correctedSwipeReplacesCommittedWordAndPreservesSpace() {
        input.commitText("helo ", 1)
        assertEquals("helo ", input.getTextBeforeCursor(100, 0).toString())
        input.beginBatchEdit()
        input.setComposingRegion(0, 4)
        input.commitText("hello", 1)
        input.endBatchEdit()
        input.finishComposingText()
        assertEquals("hello ", remote)
        assertEquals(5, position)
        assertEquals("hello ", input.editable.toString())
    }
    @Test fun correctionThroughDeleteAndInsertDoesNotAppendOldWord() {
        input.commitText("echo wrld", 1)
        input.deleteSurroundingText(4, 0)
        input.commitText("world", 1)
        assertEquals("echo world", remote)
    }
    @Test fun selectedTextAndSurrogateReplacementUseCodepointBoundaries() {
        input.commitText("x🐑", 1)
        input.setSelection(1, 3)
        input.commitText("🐏", 1)
        assertEquals("x🐏", remote)
        assertEquals(1, edits.last().erase)
    }
    @Test fun rejectedEditAndClosedConnectionForgetContext() {
        input.commitText("hello", 1)
        accept = false
        assertFalse(input.commitText("!", 1))
        assertEquals("hello", remote)
        assertEquals("", input.editable.toString())
        input.closeConnection()
        assertFalse(input.commitText("late", 1))
    }
    @Test fun contextIsBoundedWithoutDeletingRemoteText() {
        input.commitText("a".repeat(600), 1)
        assertEquals(600, remote.length)
        assertEquals(512, input.editable.length)
        input.setComposingRegion(508, 512)
        input.commitText("word", 1)
        assertEquals("a".repeat(596) + "word", remote)
    }
    @Test fun enterForgetsPreviouslySubmittedLine() {
        input.commitText("echo hi", 1)
        input.performEditorAction(EditorInfo.IME_ACTION_DONE)
        assertEquals("", input.getTextBeforeCursor(100, 0).toString())
    }
    @Test fun utf16BackspaceDeletesWholeSupplementaryCharacter() {
        input.commitText("🐑", 1)
        input.deleteSurroundingText(1, 0)
        assertEquals("", remote)
        assertEquals("", edits.last().text)
        assertEquals(1, edits.last().erase)
    }
    @Test fun deletionCrossesRetainedContextBoundary() {
        input.commitText("a".repeat(600), 1)
        input.deleteSurroundingText(513, 0)
        assertEquals("a".repeat(87), remote)
        assertEquals(1, edits.last().extraBefore)
        assertEquals("", input.editable.toString())
    }
    @Test fun forwardDeletionCrossesOwnedContextBoundary() {
        remote = "previous"; position = 0
        input.commitText("new", 1)
        input.deleteSurroundingText(0, 2)
        assertEquals("newevious", remote)
        assertEquals(2, edits.last().extraAfter)
        assertEquals("", input.editable.toString())
    }
    @Test fun totalPreeditContextIsBounded() {
        assertTrue(input.setComposingText("a".repeat(16384), 1))
        input.setComposingRegion(16384, 16384)
        assertFalse(input.setComposingText("b".repeat(513), 1))
        assertEquals(16384, input.editable.length)
        assertEquals("", remote)
    }
    @Test fun correctionNotificationDoesNotDuplicateCommittedReplacement() {
        input.commitText("helo", 1)
        input.setComposingRegion(0, 4)
        input.commitText("hello", 1)
        input.commitCorrection(android.view.inputmethod.CorrectionInfo(0, "helo", "hello"))
        assertEquals("hello", remote)
    }
    @Test fun invalidInputIsBounded() {
        assertFalse(input.deleteSurroundingText(1000000, 0))
        assertFalse(input.commitText("a".repeat(16385), 1))
        assertTrue(text.isEmpty()); assertTrue(keys.isEmpty())
    }
}
