use codex_health_usage::Reader;
fn main() {
    let root = std::env::args()
        .nth(1)
        .expect("Pass an explicitly selected Codex root");
    let snapshot = Reader::default()
        .load(std::path::Path::new(&root), chrono::Utc::now())
        .expect("Unable to read selected fixture");
    println!("{}", serde_json::to_string(&snapshot).unwrap());
}
