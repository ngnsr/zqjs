function CustomError(msg) {
  this.message = msg;
}
CustomError.prototype.name = "CustomError";

print("before throw");
throw new CustomError("something failed");
