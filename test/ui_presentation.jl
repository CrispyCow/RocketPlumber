#=
Scope: Context-independent UI scaling, typography, and numeric formatting
Formatter: Runic
=#

@testset "UI module conversion without a context" begin
    scales = instances(RocketPlumber.UIScale)
    @test map(RocketPlumber.ui_module_size, scales) == (3, 4, 5, 6, 7, 8)
    for (index, scale) in enumerate(scales)
        @test @inferred(RocketPlumber.ui_px(75, scale)) === Float64(75 * (index + 2))
        @test RocketPlumber.ui_px(0, scale) === 0.0
        @test RocketPlumber.ui_px(-2, scale) === Float64(-2 * (index + 2))
        @test RocketPlumber.ui_px(Int32(1), scale) === Float64(index + 2)
        @test RocketPlumber.ui_px(4, scale) == RocketPlumber.ui_font_size(scale, RocketPlumber.FontStandard)
        @test_throws MethodError RocketPlumber.ui_px(1.5, scale)
    end
    @test RocketPlumber.ui_px(10) === 40.0
    @test_throws MethodError RocketPlumber.ui_px(2.0)
end

@testset "Typography mappings" begin
    scales = instances(RocketPlumber.UIScale)
    classes = instances(RocketPlumber.UIFontClass)
    @test length(scales) == 6
    @test length(classes) == 4
    @test RocketPlumber.current_ui_scale() == RocketPlumber.UIScale133
    @test RocketPlumber.ui_font_size(RocketPlumber.current_ui_scale(), RocketPlumber.FontStandard) == 16
    progression = sort(collect(keys(RocketPlumber.UI_FONT_SOURCES)))
    for (index, scale) in enumerate(scales)
        standard = RocketPlumber.ui_font_size(scale, RocketPlumber.FontStandard)
        @test standard == 8 + 4index
        @test RocketPlumber.ui_font_size(scale, RocketPlumber.FontDisplay) == 2standard
        @test RocketPlumber.ui_font_size(scale, RocketPlumber.FontLarge) == progression[index + 1]
        @test RocketPlumber.ui_font_size(scale, RocketPlumber.FontExtraLarge) == progression[index + 2]
        for class in classes
            size = RocketPlumber.ui_font_size(scale, class)
            native = RocketPlumber.ui_font_source(size)
            @test native in RocketPlumber.TAMZEN_NATIVE_SIZES
            @test size % native == 0
            @test size ÷ native in (1, 2, 4)
        end
    end
    @test_throws ArgumentError RocketPlumber.ui_font_source(18)
end

@testset "Remaining delta-V component formatting" begin
    for (value, expected) in (
            (0.0, "0.00"), (-0.0049, "0.00"), (-3.742, "-3.74"),
            (99.994, "99.99"), (99.999, "100.0"), (-99.999, "-100.0"),
            (123.456, "123.5"), (999.94, "999.9"), (999.96, "1000"),
            (1234.56, "1235"), (999999.49, "999999"), (999999.5, "1e+06"),
            (-999999.5, "-1e+06"), (Inf, "Inf"), (-Inf, "-Inf"), (NaN, "NaN"),
            (floatmax(Float64), "1.8e+308"), (-1.234e308, "-1.23e+308"),
        )
        @test RocketPlumber._format_remaining_delta_v(value) == expected
    end
end
