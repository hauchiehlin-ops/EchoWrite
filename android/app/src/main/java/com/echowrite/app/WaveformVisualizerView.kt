package com.echowrite.app

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View
import kotlin.math.sin

/**
 * Android 聲波動態視覺化視圖 (Waveform Visualizer)
 * 根據麥克風 RMS 音量即時繪製 7 條霓虹青色音量柱。
 */
class WaveformVisualizerView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private val barCount = 7
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#00E5FF")
        style = Paint.Style.FILL
    }
    private val barRect = RectF()
    private var currentAmplitude = 0f

    fun updateAmplitude(amplitude: Float) {
        currentAmplitude = amplitude.coerceIn(0f, 1f)
        postInvalidateOnAnimation()
    }

    fun reset() {
        currentAmplitude = 0f
        postInvalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0 || h <= 0) return

        val barWidth = 6f * resources.displayMetrics.density
        val totalBarsWidth = barCount * barWidth
        val spacing = if (barCount > 1) (w - totalBarsWidth) / (barCount - 1) else 0f
        val cornerRadius = 3f * resources.displayMetrics.density

        for (i in 0 until barCount) {
            val left = i * (barWidth + spacing)
            val right = left + barWidth
            val waveFactor = sin(i.toDouble() / barCount.toDouble() * Math.PI).toFloat()
            val minHeight = 4f * resources.displayMetrics.density
            val dynamicHeight = (h * currentAmplitude * waveFactor * (0.8f + (i % 3) * 0.15f)).coerceAtLeast(minHeight)
            val top = (h - dynamicHeight) / 2f
            val bottom = top + dynamicHeight

            barRect.set(left, top, right, bottom)
            canvas.drawRoundRect(barRect, cornerRadius, cornerRadius, paint)
        }
    }
}
