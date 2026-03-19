export default function HelloSsr() {
  async function handleSubmit(formData) {
    'use server'
    const rawFormData = {
      username: formData.get('username'),
    }
    console.log({ rawFormData });
  }
  return (
    <main>
      <form action={handleSubmit}>
        <input type="text" name="username" required  defaultValue={"Nurul"}/>
        <input type="submit" value="Submit" />
      </form>
    </main>
  );
}



export const dynamic = "force-dynamic";