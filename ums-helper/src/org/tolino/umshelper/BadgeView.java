package org.tolino.umshelper;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.util.TypedValue;
import android.view.View;

/**
 * A line-art badge for the USB-mode screens: a circle containing a glyph.
 *
 * <p>Drawn with Canvas rather than shipped as an image, so there are no resources in the APK and
 * the glyphs stay crisp at any density. Deliberately static - the e-ink panel is greyscale and slow
 * to refresh, so nothing here animates.
 */
class BadgeView extends View {

    /** Two-way arrows: the library is on both devices. */
    static final int GLYPH_TRANSFER = 0;
    /** A circular arrow: the library is on its way back. */
    static final int GLYPH_RETURN = 1;

    private static final int INK = Color.parseColor("#333333");

    private final Paint stroke = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final int glyph;
    private final int sizePx;

    BadgeView(Context context, int glyph) {
        super(context);
        this.glyph = glyph;
        this.sizePx = dp(104);
        stroke.setStyle(Paint.Style.STROKE);
        stroke.setColor(INK);
        stroke.setStrokeCap(Paint.Cap.ROUND);
        stroke.setStrokeJoin(Paint.Join.ROUND);
    }

    private int dp(float v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v,
                getResources().getDisplayMetrics());
    }

    @Override
    protected void onMeasure(int widthSpec, int heightSpec) {
        setMeasuredDimension(sizePx, sizePx);
    }

    @Override
    protected void onDraw(Canvas canvas) {
        float cx = getWidth() / 2f;
        float cy = getHeight() / 2f;
        float radius = Math.min(getWidth(), getHeight()) / 2f - dp(2);

        stroke.setStrokeWidth(dp(2.5f));
        canvas.drawCircle(cx, cy, radius, stroke);

        stroke.setStrokeWidth(dp(3f));
        if (glyph == GLYPH_TRANSFER) {
            drawTransfer(canvas, cx, cy, radius);
        } else {
            drawReturn(canvas, cx, cy, radius);
        }
    }

    /** Two horizontal arrows, pointing opposite ways. */
    private void drawTransfer(Canvas canvas, float cx, float cy, float radius) {
        float half = radius * 0.46f;
        float gap = radius * 0.24f;
        float head = dp(6);

        float topY = cy - gap;
        canvas.drawLine(cx - half, topY, cx + half - head * 0.5f, topY, stroke);
        arrowHead(canvas, cx + half, topY, 0, head);

        float bottomY = cy + gap;
        canvas.drawLine(cx + half, bottomY, cx - half + head * 0.5f, bottomY, stroke);
        arrowHead(canvas, cx - half, bottomY, 180, head);
    }

    /** A near-complete arc with an arrowhead - "coming back round". */
    private void drawReturn(Canvas canvas, float cx, float cy, float radius) {
        float ar = radius * 0.46f;
        RectF oval = new RectF(cx - ar, cy - ar, cx + ar, cy + ar);
        float startAngle = -55f;
        float sweep = 285f;
        canvas.drawArc(oval, startAngle, sweep, false, stroke);

        // arrowhead on the leading end of the arc
        double endRad = Math.toRadians(startAngle + sweep);
        float ex = cx + (float) (Math.cos(endRad) * ar);
        float ey = cy + (float) (Math.sin(endRad) * ar);
        arrowHead(canvas, ex, ey, (float) (startAngle + sweep + 90), dp(6));
    }

    /** Two short strokes forming a chevron; {@code angleDeg} is the direction it points. */
    private void arrowHead(Canvas canvas, float x, float y, float angleDeg, float size) {
        double spread = Math.toRadians(150);
        double a = Math.toRadians(angleDeg);
        canvas.drawLine(x, y, x + (float) (Math.cos(a + spread) * size),
                y + (float) (Math.sin(a + spread) * size), stroke);
        canvas.drawLine(x, y, x + (float) (Math.cos(a - spread) * size),
                y + (float) (Math.sin(a - spread) * size), stroke);
    }
}
