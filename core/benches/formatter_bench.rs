// 效能基準：formatter::format_text 是唯一不需要下載模型、不需要真機/模擬器
// 就能在任何開發機或 CI 上量測的核心邏輯（ASR/LLM 推理需要數百 MB ~ 1GB 的
// 模型檔案與真實麥克風/GPU，不適合放進一般效能基準）。
//
// 執行方式：`cargo bench -p echowrite-core`

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use echowrite_core::formatter::format_text;

fn short_sentence() -> String {
    "我的屏幕壞了,所以我買了個新的硬件。這是我最近開發的軟件project。".to_string()
}

fn long_paragraph() -> String {
    // 模擬一段較長的語音轉寫逐字稿，包含多個需要轉換的詞彙與中英夾雜情境，
    // 反覆串接以檢驗正則表達式在長文本下的效能表現。
    let unit = "服務器上的數據庫算法需要用戶激活菜單才能支持新功能,這個project目前已經有100個用戶在使用了.";
    unit.repeat(50)
}

fn bench_format_text(c: &mut Criterion) {
    let short = short_sentence();
    let long = long_paragraph();

    let mut group = c.benchmark_group("formatter::format_text");
    group.bench_function("short_sentence", |b| {
        b.iter(|| format_text(black_box(short.clone())))
    });
    group.bench_function("long_paragraph_5kb", |b| {
        b.iter(|| format_text(black_box(long.clone())))
    });
    group.finish();
}

criterion_group!(benches, bench_format_text);
criterion_main!(benches);
