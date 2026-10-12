import type { Snapshot } from "./types";
import { exact } from "./types";
export async function receiptPNG(s: Snapshot): Promise<Uint8Array> {
  await document.fonts.ready;
  const logo = new Image();
  logo.src = "/icons/flat-light.png";
  await logo.decode();
  const canvas = document.createElement("canvas");
  canvas.width = 1080;
  canvas.height = 2310;
  const c = canvas.getContext("2d");
  if (!c) throw new Error("图片绘制不可用");
  c.scale(3, 3);
  c.fillStyle = "#fff";
  c.beginPath();
  c.moveTo(0, 0);
  for (let i = 0; i < 36; i++) {
    c.lineTo(i * 10 + 5, 5);
    c.lineTo(i * 10 + 10, 0);
  }
  c.lineTo(360, 770);
  for (let i = 35; i >= 0; i--) {
    c.lineTo(i * 10 + 5, 765);
    c.lineTo(i * 10, 770);
  }
  c.closePath();
  c.fill();
  c.fillStyle = "#30332e";
  const text = (
    t: string,
    y: number,
    size = 11,
    align: CanvasTextAlign = "center",
    bold = false,
  ) => {
    c.font = `${bold ? "bold " : ""}${size}px "Segoe UI", sans-serif`;
    c.textAlign = align;
    c.fillText(
      t,
      align === "left" ? 28 : align === "right" ? 332 : 180,
      y,
      304,
    );
  };
  const rule = (y: number) => {
    c.strokeStyle = "#aaa";
    c.setLineDash([3, 4]);
    c.beginPath();
    c.moveTo(28, y);
    c.lineTo(332, y);
    c.stroke();
    c.setLineDash([]);
  };
  const row = (a: string, b: string, y: number) => {
    text(a, y, 11, "left");
    text(b, y, 11, "right");
  };
  c.drawImage(logo, 156, 25, 48, 48);
  text("CODEX HEALTH", 94, 21, "center", true);
  text("WEEKLY USAGE RECEIPT", 116, 10);
  text("近 7 天用量小票", 139, 12);
  rule(162);
  text(
    `${s.dailyUsage[0]?.date ?? ""} — ${s.dailyUsage.at(-1)?.date ?? ""}`,
    185,
  );
  text(`截至 ${new Date(s.observedAt).toLocaleString()}`, 205, 10);
  rule(226);
  row("日期 / DATE", "TOKENS", 250);
  s.dailyUsage.forEach((d, i) =>
    row(d.date.slice(5).replace("-", "/"), exact(d.tokens), 280 + i * 27),
  );
  rule(465);
  row("输入", exact(s.lastSevenDays.input), 493);
  row("缓存输入（含于输入）", exact(s.lastSevenDays.cachedInput), 521);
  row("输出", exact(s.lastSevenDays.output), 549);
  row("推理输出（含于输出）", exact(s.lastSevenDays.reasoningOutput), 577);
  rule(600);
  row("合计 / TOTAL", "TOKEN", 625);
  text(exact(s.lastSevenDays.total), 665, 32, "right", true);
  c.save();
  c.translate(180, 704);
  c.rotate(-0.06);
  c.strokeStyle = "#914d40";
  c.fillStyle = "#914d40";
  c.lineWidth = 2;
  c.strokeRect(-85, -20, 170, 38);
  c.font = 'bold 20px "Segoe UI", sans-serif';
  c.textAlign = "center";
  c.fillText("本机已记录", 0, 6);
  c.restore();
  text(
    s.warnings.length ? "部分记录读取不完整" : "记录所选目录的 Token 用量",
    745,
    9,
  );
  const blob = await new Promise<Blob>((resolve, reject) =>
    canvas.toBlob(
      (b) => (b ? resolve(b) : reject(new Error("PNG 编码失败"))),
      "image/png",
    ),
  );
  return new Uint8Array(await blob.arrayBuffer());
}
