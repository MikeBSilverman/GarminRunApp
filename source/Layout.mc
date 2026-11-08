import Toybox.Graphics;
import Toybox.Lang;

// Proportional layout: positions are percentages of the field size, tuned on
// the fr965's 454x454 round screen. Trimmed from Lift's Layout.mc.
module Layout {
    const VCENTER = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;

    // Rows, % of height. The band can't go higher: it clips on the round bezel.
    const BAND_Y1 = 16;         // band line 1 (with a line 2)
    const BAND_Y2 = 23;
    const BAND_Y_SINGLE = 18;   // band line 1 alone
    const BAND_FILL = 28;       // coloured band height
    const HERO_Y = 39;
    const LABEL_Y = 53;         // hero label: clear of the hero (Mike's ask)
    const ROW2_Y = 61;
    const ROW2_LABEL_Y = 69;
    const DIVIDER_TOP = 57;
    const DIVIDER_BOTTOM = 74;
    const ROW3_Y = 79;
    const ROW3_LABEL_Y = 87;

    // Columns, % of width. Row 3's three columns fit the chord at 87% height.
    const ROW2_LEFT_X = 30;
    const ROW2_RIGHT_X = 70;
    const TIME_X = 28;
    const HR_X = 54;
    const CAD_X = 76;

    // Pills behind a value (GEL n, HR over the cap): the full font height
    // touches the next row.
    const PILL_HEIGHT_PCT = 80;

    // 240/260/280 MIP screens need a font step down; 360+ AMOLED keep full size.
    function isSmall(h as Number) as Boolean {
        return h <= 320;
    }

    function heroFont(h as Number) as Graphics.FontDefinition {
        return isSmall(h) ? Graphics.FONT_NUMBER_MILD : Graphics.FONT_NUMBER_MEDIUM;
    }

    function valueFont(h as Number) as Graphics.FontDefinition {
        return isSmall(h) ? Graphics.FONT_MEDIUM : Graphics.FONT_LARGE;
    }

    function rowFont(h as Number) as Graphics.FontDefinition {
        return isSmall(h) ? Graphics.FONT_SMALL : Graphics.FONT_MEDIUM;
    }

    function bandFont(h as Number) as Graphics.FontDefinition {
        return isSmall(h) ? Graphics.FONT_TINY : Graphics.FONT_SMALL;
    }

    function labelFont() as Graphics.FontDefinition {
        return Graphics.FONT_XTINY;
    }

    function pct(size as Number, p as Number) as Number {
        return size * p / 100;
    }

    // A rounded pill of `color` behind `text` centred at (x, y), `padPx`
    // wider than the text. The caller draws the text over it.
    function drawPill(dc as Graphics.Dc, x as Number, y as Number, text as String,
                      font as Graphics.FontDefinition, padPx as Number, color as Number) as Void {
        var dims = dc.getTextDimensions(text, font);
        var pw = dims[0] + padPx;
        var ph = dims[1] * PILL_HEIGHT_PCT / 100;
        dc.setColor(color, color);
        dc.fillRoundedRectangle(x - pw / 2, y - ph / 2, pw, ph, ph / 4);
    }
}
