// #[macro_use]
// extern crate anyhow;
mod config;

use config::Opts;

use nvim_oxi as oxi;
use oxi::{
    api::{self, opts::*, types::*, Error},
    Dictionary, Function,
};

fn setup(cmd_opts: Opts) -> Result<(), Error> {
    todo!()
}


#[oxi::module]
fn typst() -> oxi::Result<Dictionary> {
    Ok(Dictionary::from_iter([
        ("setup", Function::from_fn(setup)),
    ]))
}