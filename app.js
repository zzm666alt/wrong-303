/* 辅助交互：密码显示、编辑行快速回填、删除二次确认。
 * 全部实际读写由 Python 后端调用 SQL Server 存储过程完成。 */
document.querySelectorAll(".reveal-password").forEach((button) => {
  button.addEventListener("click", () => {
    const field = button.parentElement.querySelector('input[type="password"], input[type="text"]');
    if (!field) return;
    const revealing = field.type === "password";
    field.type = revealing ? "text" : "password";
    button.textContent = revealing ? "隐藏" : "显示";
    button.setAttribute("aria-label", revealing ? "隐藏密码" : "显示密码");
  });
});

document.querySelectorAll("[data-prefill]").forEach((button) => {
  button.addEventListener("click", () => {
    const kind = button.dataset.prefill;
    const form = document.getElementById("form-" + kind);
    if (!form) return;
    const data = button.dataset;
    const values = {
      student_id: data.studentId || "",
      owner_name: data.ownerName || "",
      phone: data.phone || "",
      counselor: data.counselor || "",
      old_plate: data.plate || "",
      new_plate: data.plate || "",
      new_model: data.model || "",
      plate_number: data.plate || "",
    };
    Object.entries(values).forEach(([name, value]) => {
      const input = form.elements.namedItem(name);
      if (input) input.value = value;
    });
    const section = form.closest("details");
    if (section) section.open = true;
    form.scrollIntoView({ behavior: "smooth", block: "center" });
    form.querySelector('input[name="new_plate"], input[name="plate_number"]')?.focus({ preventScroll: true });
  });
});

document.querySelectorAll("form[data-confirm]").forEach((form) => {
  form.addEventListener("submit", (event) => {
    if (!window.confirm(form.dataset.confirm)) event.preventDefault();
  });
});
