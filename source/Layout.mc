import Toybox.Graphics;
import Toybox.Lang;

// Proportional layout: positions are percentages of the field size, tuned on
// the fr965's 454x454 round screen. Trimmed from Lift's Layout.mc.
module Layout {
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
}
